import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'catch_up_state.dart';
import 'models.dart';

/// On-device persistence so Recall opens instantly and works offline:
///  - a snapshot of the last-loaded decks + study queue, and
///  - an append-only outbox of reviews done while offline (or that failed to
///    sync), flushed to Supabase on the next launch/foreground.
///
/// Supabase remains the source of truth; this cache is disposable.
///
/// Outbox mutations are serialized through [_withOutboxLock]: the flush now
/// runs behind the UI, so an enqueue (new rating) can arrive while a flush is
/// rewriting the list — unserialized, that read-modify-write race can
/// resurrect an already-sent review (double-apply) or drop a fresh one.
///
/// Note flags (bad-card reports) live in their own [_flagOutboxKey] list with
/// the same enqueue/read/remove shape as the review outbox, sharing the one
/// lock so a flag write never races a review write. They flush through a
/// separate loop in the controller so a flag delivery failure (e.g. the
/// note_flags table not existing yet) can never stall the review sync.
class LocalReviewStore {
  static const _snapshotKey = 'recall_snapshot_v1';
  static const _outboxKey = 'recall_outbox_v1';
  static const _flagOutboxKey = 'flag_outbox_v1';
  static const catchUpKey = 'recall_catch_up_v1';
  static const installIdKey = 'recall_install_id_v1';

  Future<void> _outboxTail = Future.value();
  Future<SharedPreferences>? _prefsFuture;
  String? _installId;
  int _eventSequence = 0;

  Future<SharedPreferences> get _prefs =>
      _prefsFuture ??= SharedPreferences.getInstance();

  /// Random source for durable ids. `Random.secure()` can be unavailable on
  /// some embedders; uniqueness (not unpredictability) is what matters here,
  /// so a plain PRNG is an acceptable fallback.
  static final Random _random = () {
    try {
      return Random.secure();
    } on UnsupportedError {
      return Random();
    }
  }();

  /// This installation's stable identity, minted once and reused for the life
  /// of the install. It scopes durable event ids to one device so two devices
  /// studying the same collection can never mint the same id.
  ///
  /// Deliberately NOT cleared by [clear]: it identifies the device, not the
  /// user, and keeping it stable across sign-out preserves the uniqueness
  /// guarantee for reviews still queued from a previous session.
  Future<String> installId() {
    final cached = _installId;
    if (cached != null) return Future.value(cached);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      var value = prefs.getString(installIdKey);
      if (value == null || value.isEmpty) {
        value = _token();
        await prefs.setString(installIdKey, value);
      }
      return _installId = value;
    });
  }

  /// A durable, globally unique id for one study action.
  ///
  /// Three parts, each covering a different collision: the install id
  /// separates devices, the counter separates actions within a run, and the
  /// random suffix separates runs. The suffix is what makes the id independent
  /// of the clock — the outbox outlives a restart while the counter resets, so
  /// a device whose clock rolled back would otherwise mint an id it had
  /// already used and the server would discard the review as a replay.
  Future<String> newEventId() async {
    final install = await installId();
    return '$install-${++_eventSequence}-${_token()}';
  }

  /// ~62 bits of entropy over a lowercase-alphanumeric alphabet.
  ///
  /// Deliberately built from small `nextInt` draws rather than shifted 32-bit
  /// integers: Recall also builds to web, where Dart ints are JS doubles and a
  /// `1 << 32` would silently collapse to 1 — every token would be identical
  /// on exactly the platform where this is hardest to notice.
  static String _token([int length = 12]) {
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(_random.nextInt(alphabet.length)),
    ]);
  }

  Future<T> _withOutboxLock<T>(Future<T> Function() action) {
    final run = _outboxTail.then((_) => action());
    // Keep the chain alive past failures so one error can't wedge the lock.
    _outboxTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
    int? globalDueCount,
    DateTime? globalDueUpdatedAt,
    bool Function()? canWrite,
  }) async {
    await _withOutboxLock(() async {
      final prefs = await _prefs;
      if (canWrite != null && !canWrite()) return;
      await prefs.setString(
        _snapshotKey,
        jsonEncode({
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'globalDueCount': globalDueCount,
          'globalDueUpdatedAt': globalDueUpdatedAt?.toUtc().toIso8601String(),
          'decks': [for (final d in decks) d.toJson()],
          'queue': [for (final c in queue) c.toJson()],
        }),
      );
    });
  }

  Future<
    ({
      List<DeckRow> decks,
      List<ReviewCard> queue,
      int? globalDueCount,
      DateTime? globalDueUpdatedAt,
    })?
  >
  loadSnapshot() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_snapshotKey);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        decks: [
          for (final d in (m['decks'] as List))
            DeckRow.fromJson(Map<String, dynamic>.from(d as Map)),
        ],
        queue: [
          for (final c in (m['queue'] as List))
            ReviewCard.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        globalDueCount: (m['globalDueCount'] as num?)?.toInt(),
        globalDueUpdatedAt: m['globalDueUpdatedAt'] == null
            ? null
            : DateTime.tryParse(m['globalDueUpdatedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  /// Append one review; returns the new pending count so the caller can
  /// update its badge without re-reading + re-decoding the whole outbox.
  Future<int> enqueueReview(Map<String, dynamic> entry) {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readOutbox(prefs)..add(entry);
      await _writeList(prefs, _outboxKey, list);
      return list.length;
    });
  }

  /// Read the queued reviews. Serialized through the outbox lock so a flush
  /// starting right after an undo's [removeEntry] can never read the stale
  /// pre-removal list and deliver a review the user just took back.
  Future<List<Map<String, dynamic>>> outbox() {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      return _readOutbox(prefs);
    });
  }

  /// Drop the first [count] entries — the prefix a flush just delivered —
  /// and return how many remain. Entries enqueued while the flush ran are
  /// appended after that prefix, so they survive untouched.
  Future<int> removeFirst(int count) {
    if (count <= 0) {
      return _withOutboxLock(() async {
        final prefs = await _prefs;
        return _readOutbox(prefs).length;
      });
    }
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readOutbox(prefs);
      final remaining = list.length <= count
          ? <Map<String, dynamic>>[]
          : list.sublist(count);
      await _writeList(prefs, _outboxKey, remaining);
      return remaining.length;
    });
  }

  /// Drop the queued review whose `client_id` matches — the not-yet-flushed
  /// rating the user just undid. Returns whether an entry was removed (false
  /// means a flush already delivered it) and the new pending count.
  Future<({bool removed, int remaining})> removeEntry(Object clientId) {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readOutbox(prefs);
      final before = list.length;
      list.removeWhere((e) => e['client_id'] == clientId);
      if (list.length != before) {
        await _writeList(prefs, _outboxKey, list);
      }
      return (removed: list.length != before, remaining: list.length);
    });
  }

  /// Read the local-only catch-up choice and today's progress. Corrupt or old
  /// presentation state is disposable, so it falls back to opt-out rather
  /// than affecting the review outbox or queue load.
  Future<CatchUpLocalState> loadCatchUpState() async {
    final prefs = await _prefs;
    final raw = prefs.getString(catchUpKey);
    if (raw == null) return CatchUpLocalState.none;
    try {
      return CatchUpLocalState.fromJson(jsonDecode(raw));
    } catch (_) {
      return CatchUpLocalState.none;
    }
  }

  Future<void> saveCatchUpState(CatchUpLocalState state) {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final written = await prefs.setString(
        catchUpKey,
        jsonEncode(state.toJson()),
      );
      if (!written) throw LocalOutboxWriteException(catchUpKey);
    });
  }

  // --- Flag outbox ---
  //
  // A bad-card report queued mid-review. Mirrors the review outbox exactly
  // (append-only, oldest-first drain, shared lock) but is a wholly separate
  // list so its flush is isolated from the review flush.

  /// Append one flag; returns the new pending flag count.
  Future<int> enqueueFlag(Map<String, dynamic> entry) {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readList(prefs, _flagOutboxKey)..add(entry);
      await _writeList(prefs, _flagOutboxKey, list);
      return list.length;
    });
  }

  /// Read the queued flags (serialized through the shared outbox lock).
  Future<List<Map<String, dynamic>>> flagOutbox() {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      return _readList(prefs, _flagOutboxKey);
    });
  }

  /// Drop the first [count] flags — the prefix a flag flush just delivered —
  /// and return how many remain. Flags enqueued while the flush ran are
  /// appended after that prefix, so they survive untouched.
  Future<int> removeFirstFlag(int count) {
    if (count <= 0) {
      return _withOutboxLock(() async {
        final prefs = await _prefs;
        return _readList(prefs, _flagOutboxKey).length;
      });
    }
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readList(prefs, _flagOutboxKey);
      final remaining = list.length <= count
          ? <Map<String, dynamic>>[]
          : list.sublist(count);
      await _writeList(prefs, _flagOutboxKey, remaining);
      return remaining.length;
    });
  }

  /// Drop the cached snapshot + outboxes (called on sign-out so the next user
  /// on a shared browser can't see the previous user's cards/reviews/flags).
  Future<void> clear() {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      await prefs.remove(_snapshotKey);
      await prefs.remove(_outboxKey);
      await prefs.remove(_flagOutboxKey);
      await prefs.remove(catchUpKey);
    });
  }

  List<Map<String, dynamic>> _readOutbox(SharedPreferences prefs) =>
      _readList(prefs, _outboxKey);

  List<Map<String, dynamic>> _readList(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List))
          Map<String, dynamic>.from(e as Map),
      ];
    } catch (error) {
      // A malformed durable outbox is not the same as an empty one. Failing
      // closed keeps sign-out and sync from silently deleting study actions
      // that need recovery.
      throw LocalOutboxCorruptException(key, error);
    }
  }

  Future<void> _writeList(
    SharedPreferences prefs,
    String key,
    List<Map<String, dynamic>> list,
  ) async {
    final written = await prefs.setString(key, jsonEncode(list));
    if (!written) {
      throw LocalOutboxWriteException(key);
    }
  }
}

class LocalOutboxCorruptException implements Exception {
  final String key;
  final Object cause;
  const LocalOutboxCorruptException(this.key, this.cause);

  @override
  String toString() =>
      'Recall could not read the pending study actions ($key).';
}

class LocalOutboxWriteException implements Exception {
  final String key;
  const LocalOutboxWriteException(this.key);

  @override
  String toString() => 'Recall could not save the pending study action ($key).';
}

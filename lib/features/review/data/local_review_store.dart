import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
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
  static const remediationKey = 'recall_remediation_v1';
  static const installIdKey = 'recall_install_id_v1';
  static const _legacyOwnerClaimKey = 'recall_local_state_owner_v1';
  static const _ownerMigrationKey = 'recall_local_state_migrated_v1';
  static const maxDailyRemediations = 3;

  Future<void> _outboxTail = Future.value();
  Future<SharedPreferences>? _prefsFuture;
  String? _installId;
  int _eventSequence = 0;
  String? _activeOwnerScope;
  bool _ownerAware = false;

  String? get activeOwnerScope => _activeOwnerScope;

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

  /// Select the account namespace used by every cache and durable outbox.
  ///
  /// The first upgraded account claims the legacy unscoped values. They are
  /// copied once, then left untouched as recovery evidence; later accounts can
  /// never inherit them. The install id deliberately remains device-scoped.
  Future<void> activateOwner(String ownerId) {
    if (ownerId.trim().isEmpty) {
      return Future.error(ArgumentError.value(ownerId, 'ownerId'));
    }
    final scope = sha256
        .convert(utf8.encode(ownerId))
        .toString()
        .substring(0, 24);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final claimed = prefs.getString(_legacyOwnerClaimKey);
      if (claimed == null) {
        if (!await prefs.setString(_legacyOwnerClaimKey, scope)) {
          throw LocalOutboxWriteException(_legacyOwnerClaimKey);
        }
      }
      final ownerClaim = claimed ?? scope;
      final migrationKey = '$_ownerMigrationKey:$scope';
      if (ownerClaim == scope && prefs.getBool(migrationKey) != true) {
        for (final base in [
          _snapshotKey,
          _outboxKey,
          _flagOutboxKey,
          catchUpKey,
          remediationKey,
        ]) {
          final legacy = prefs.getString(base);
          final scoped = _scopedKey(base, scope);
          if (legacy != null && prefs.getString(scoped) == null) {
            if (!await prefs.setString(scoped, legacy)) {
              throw LocalOutboxWriteException(scoped);
            }
          }
        }
        if (!await prefs.setBool(migrationKey, true)) {
          throw LocalOutboxWriteException(migrationKey);
        }
      }
      _ownerAware = true;
      _activeOwnerScope = scope;
    });
  }

  Future<void> releaseOwner() => _withOutboxLock(() async {
    _ownerAware = true;
    _activeOwnerScope = null;
  });

  String _storageKey(String base, {String? ownerScope}) {
    final scope = ownerScope ?? _activeOwnerScope;
    if (scope != null) return _scopedKey(base, scope);
    if (_ownerAware) {
      throw StateError('Recall local state has no active owner.');
    }
    return base;
  }

  static String _scopedKey(String base, String scope) => '$base:owner:$scope';

  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
    int? deckId,
    int? globalDueCount,
    DateTime? globalDueUpdatedAt,
    bool Function()? canWrite,
  }) async {
    final snapshotKey = _snapshotStorageKey(deckId);
    await _withOutboxLock(() async {
      final prefs = await _prefs;
      if (canWrite != null && !canWrite()) return;
      await prefs.setString(
        snapshotKey,
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
  loadSnapshot({int? deckId}) async {
    final snapshotKey = _snapshotStorageKey(deckId);
    final prefs = await _prefs;
    final raw = prefs.getString(snapshotKey);
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

  String _snapshotStorageKey(int? deckId, {String? ownerScope}) {
    final base = _storageKey(_snapshotKey, ownerScope: ownerScope);
    return deckId == null ? base : '$base:deck:$deckId';
  }

  /// Append one review; returns the new pending count so the caller can
  /// update its badge without re-reading + re-decoding the whole outbox.
  Future<int> enqueueReview(Map<String, dynamic> entry) {
    final key = _storageKey(_outboxKey);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readOutbox(prefs, key)..add(entry);
      await _writeList(prefs, key, list);
      return list.length;
    });
  }

  /// Read the queued reviews. Serialized through the outbox lock so a flush
  /// starting right after an undo's [removeEntry] can never read the stale
  /// pre-removal list and deliver a review the user just took back.
  Future<List<Map<String, dynamic>>> outbox({String? ownerScope}) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      return _readOutbox(prefs, key);
    });
  }

  /// Drop the first [count] entries — the prefix a flush just delivered —
  /// and return how many remain. Entries enqueued while the flush ran are
  /// appended after that prefix, so they survive untouched.
  Future<int> removeFirst(int count, {String? ownerScope}) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    if (count <= 0) {
      return _withOutboxLock(() async {
        final prefs = await _prefs;
        return _readOutbox(prefs, key).length;
      });
    }
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readOutbox(prefs, key);
      final remaining = list.length <= count
          ? <Map<String, dynamic>>[]
          : list.sublist(count);
      await _writeList(prefs, key, remaining);
      return remaining.length;
    });
  }

  /// Drop the queued review whose `client_id` matches — the not-yet-flushed
  /// rating the user just undid. Returns whether an entry was removed (false
  /// means a flush already delivered it) and the new pending count.
  Future<({bool removed, int remaining})> removeEntry(Object clientId) {
    final key = _storageKey(_outboxKey);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readOutbox(prefs, key);
      final before = list.length;
      list.removeWhere((e) => e['client_id'] == clientId);
      if (list.length != before) {
        await _writeList(prefs, key, list);
      }
      return (removed: list.length != before, remaining: list.length);
    });
  }

  /// Read the local-only catch-up choice and today's progress. Corrupt or old
  /// presentation state is disposable, so it falls back to opt-out rather
  /// than affecting the review outbox or queue load.
  Future<CatchUpLocalState> loadCatchUpState() async {
    final key = _storageKey(catchUpKey);
    final prefs = await _prefs;
    final raw = prefs.getString(key);
    if (raw == null) return CatchUpLocalState.none;
    try {
      return CatchUpLocalState.fromJson(jsonDecode(raw));
    } catch (_) {
      return CatchUpLocalState.none;
    }
  }

  Future<void> saveCatchUpState(CatchUpLocalState state) {
    final key = _storageKey(catchUpKey);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final written = await prefs.setString(key, jsonEncode(state.toJson()));
      if (!written) throw LocalOutboxWriteException(key);
    });
  }

  // --- Flag outbox ---
  //
  // A bad-card report queued mid-review. Mirrors the review outbox exactly
  // (append-only, oldest-first drain, shared lock) but is a wholly separate
  // list so its flush is isolated from the review flush.

  /// Append one flag; returns the new pending flag count.
  Future<int> enqueueFlag(Map<String, dynamic> entry) {
    final key = _storageKey(_flagOutboxKey);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readList(prefs, key)..add(entry);
      await _writeList(prefs, key, list);
      return list.length;
    });
  }

  /// Read the queued flags (serialized through the shared outbox lock).
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) {
    final key = _storageKey(_flagOutboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      return _readList(prefs, key);
    });
  }

  /// Drop the first [count] flags — the prefix a flag flush just delivered —
  /// and return how many remain. Flags enqueued while the flush ran are
  /// appended after that prefix, so they survive untouched.
  Future<int> removeFirstFlag(int count, {String? ownerScope}) {
    final key = _storageKey(_flagOutboxKey, ownerScope: ownerScope);
    if (count <= 0) {
      return _withOutboxLock(() async {
        final prefs = await _prefs;
        return _readList(prefs, key).length;
      });
    }
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final list = _readList(prefs, key);
      final remaining = list.length <= count
          ? <Map<String, dynamic>>[]
          : list.sublist(count);
      await _writeList(prefs, key, remaining);
      return remaining.length;
    });
  }

  /// Read the local, disposable primer-remediation queue for [now]'s local
  /// calendar day. Entries from an earlier day expire when the app next opens;
  /// the queue is a same-day nudge, not durable user history.
  Future<List<LocalRemediationItem>> remediationQueue({DateTime? now}) {
    final key = _storageKey(remediationKey);
    final today = _dayKey(now ?? DateTime.now());
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final current = _readRemediations(prefs, key)
          .where((item) => item.dayKey == today)
          .take(maxDailyRemediations)
          .toList();
      final all = _readRemediations(prefs, key);
      if (current.length != all.length) {
        await _writeList(prefs, key, [
          for (final item in current) item.toJson(),
        ]);
      }
      return current;
    });
  }

  /// Add unique same-day concept ids, keeping the oldest three. This is a
  /// local cache only: nothing here is sent to Supabase or the review outbox.
  Future<List<LocalRemediationItem>> enqueueRemediation(
    Iterable<String> nodeIds, {
    DateTime? now,
  }) {
    final key = _storageKey(remediationKey);
    final queuedAt = now ?? DateTime.now();
    final today = _dayKey(queuedAt);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final current = _readRemediations(prefs, key)
          .where((item) => item.dayKey == today)
          .take(maxDailyRemediations)
          .toList();
      final seen = {for (final item in current) item.nodeId};
      for (final nodeId in nodeIds) {
        final normalized = nodeId.trim();
        if (normalized.isEmpty || normalized == 'none') continue;
        if (current.length >= maxDailyRemediations) break;
        if (seen.add(normalized)) {
          current.add(
            LocalRemediationItem(nodeId: normalized, queuedAt: queuedAt),
          );
        }
      }
      await _writeList(prefs, key, [for (final item in current) item.toJson()]);
      return current;
    });
  }

  /// Mark one primer remediation as read. Returns false when it was already
  /// gone, which makes repeated route completions harmless.
  Future<bool> completeRemediation(String nodeId, {DateTime? now}) {
    final key = _storageKey(remediationKey);
    final today = _dayKey(now ?? DateTime.now());
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      final current = _readRemediations(prefs, key)
          .where((item) => item.dayKey == today)
          .take(maxDailyRemediations)
          .toList();
      final before = current.length;
      current.removeWhere((item) => item.nodeId == nodeId);
      await _writeList(prefs, key, [for (final item in current) item.toJson()]);
      return current.length != before;
    });
  }

  /// Drop the cached snapshot + outboxes (called on sign-out so the next user
  /// on a shared browser can't see the previous user's cards/reviews/flags).
  Future<void> clear() {
    final snapshotKey = _snapshotStorageKey(null);
    final outboxKey = _storageKey(_outboxKey);
    final flagOutboxKey = _storageKey(_flagOutboxKey);
    final catchUpStorageKey = _storageKey(catchUpKey);
    final remediationStorageKey = _storageKey(remediationKey);
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      for (final key in prefs.getKeys()) {
        if (key == snapshotKey || key.startsWith('$snapshotKey:deck:')) {
          await prefs.remove(key);
        }
      }
      await prefs.remove(outboxKey);
      await prefs.remove(flagOutboxKey);
      await prefs.remove(catchUpStorageKey);
      await prefs.remove(remediationStorageKey);
    });
  }

  List<Map<String, dynamic>> _readOutbox(SharedPreferences prefs, String key) =>
      _readList(prefs, key);

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

  List<LocalRemediationItem> _readRemediations(
    SharedPreferences prefs,
    String key,
  ) => [
    for (final entry in _readList(prefs, key))
      if (entry['node_id'] is String && entry['queued_at'] is String)
        LocalRemediationItem.fromJson(entry),
  ];

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

/// One same-day local primer-remediation item. It has no server identity and
/// is intentionally disposable; removing it is the completion state.
class LocalRemediationItem {
  final String nodeId;
  final DateTime queuedAt;

  const LocalRemediationItem({required this.nodeId, required this.queuedAt});

  String get dayKey => _dayKey(queuedAt);

  factory LocalRemediationItem.fromJson(Map<String, dynamic> json) =>
      LocalRemediationItem(
        nodeId: json['node_id'] as String,
        queuedAt: DateTime.parse(json['queued_at'] as String),
      );

  Map<String, dynamic> toJson() => {
    'node_id': nodeId,
    'queued_at': queuedAt.toUtc().toIso8601String(),
  };
}

String _dayKey(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
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

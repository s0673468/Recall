import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  Future<void> _outboxTail = Future.value();
  Future<SharedPreferences>? _prefsFuture;

  Future<SharedPreferences> get _prefs =>
      _prefsFuture ??= SharedPreferences.getInstance();

  Future<T> _withOutboxLock<T>(Future<T> Function() action) {
    final run = _outboxTail.then((_) => action());
    // Keep the chain alive past failures so one error can't wedge the lock.
    _outboxTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
  }) async {
    final prefs = await _prefs;
    await prefs.setString(
      _snapshotKey,
      jsonEncode({
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'decks': [for (final d in decks) d.toJson()],
        'queue': [for (final c in queue) c.toJson()],
      }),
    );
  }

  Future<({List<DeckRow> decks, List<ReviewCard> queue})?>
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
      await prefs.setString(_outboxKey, jsonEncode(list));
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
      await prefs.setString(_outboxKey, jsonEncode(remaining));
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
        await prefs.setString(_outboxKey, jsonEncode(list));
      }
      return (removed: list.length != before, remaining: list.length);
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
      await prefs.setString(_flagOutboxKey, jsonEncode(list));
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
      await prefs.setString(_flagOutboxKey, jsonEncode(remaining));
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
    } catch (_) {
      return [];
    }
  }
}

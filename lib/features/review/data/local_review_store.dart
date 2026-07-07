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
class LocalReviewStore {
  static const _snapshotKey = 'recall_snapshot_v1';
  static const _outboxKey = 'recall_outbox_v1';

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

  Future<List<Map<String, dynamic>>> outbox() async {
    final prefs = await _prefs;
    return _readOutbox(prefs);
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

  /// Drop the cached snapshot + outbox (called on sign-out so the next user on
  /// a shared browser can't see the previous user's cards/reviews).
  Future<void> clear() {
    return _withOutboxLock(() async {
      final prefs = await _prefs;
      await prefs.remove(_snapshotKey);
      await prefs.remove(_outboxKey);
    });
  }

  List<Map<String, dynamic>> _readOutbox(SharedPreferences prefs) {
    final raw = prefs.getString(_outboxKey);
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

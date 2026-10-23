import 'dart:async';

import 'local_review_store.dart';
import 'recall_api.dart';

/// Prefer fresh server counts online, overlaying only certainly unsent reviews.
/// Offline reads use the last accepted baseline and its local review coverage.
class OfflineDeckCounts {
  OfflineDeckCounts({
    required this.api,
    required this.store,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final RecallApi api;
  final LocalReviewStore store;
  final DateTime Function() clock;
  int _request = 0;

  Future<Map<int, ({int due, int neu})>> load({required bool offline}) async {
    final request = ++_request;
    final ownerScope = store.activeOwnerScope;
    bool current() =>
        request == _request && ownerScope == store.activeOwnerScope;
    if (!offline) {
      final boundaryFuture = store.deckCountsRefreshBoundary(
        ownerScope: ownerScope,
      );
      final response = api.fetchDeckCounts();
      // A concurrent mutation can invalidate the boundary; still consume errors.
      unawaited(response.then<void>((_) {}, onError: (Object _) {}));
      final boundary = await boundaryFuture;
      if (!current()) throw StateError('Deck count request expired');
      try {
        final fetchedAt = clock().toUtc();
        final counts = await response;
        if (!current()) throw StateError('Deck count request expired');
        if (boundary != null) {
          final accepted = await store.saveDeckCounts(
            counts,
            fetchedAt: fetchedAt,
            ownerScope: ownerScope,
            canWrite: current,
            boundary: boundary,
          );
          if (!current()) throw StateError('Deck count request expired');
          if (accepted != null) return accepted;
        }
        // Prefer local reconciliation if a review crossed this fetch, but a
        // missing/legacy cache must never make a successful online read fail.
        final snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
        if (!current()) throw StateError('Deck count request expired');
        return snapshot?.counts ?? counts;
      } catch (_) {
        if (!current()) rethrow;
        final snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
        if (!current()) throw StateError('Deck count request expired');
        if (snapshot == null) rethrow;
        return snapshot.counts;
      }
    }
    final snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
    if (!current()) throw StateError('Deck count request expired');
    if (snapshot == null) throw StateError('Deck counts unavailable offline');
    return snapshot.counts;
  }
}

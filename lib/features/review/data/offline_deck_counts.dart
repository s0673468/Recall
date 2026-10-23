import 'dart:async';

import 'local_review_store.dart';
import 'recall_api.dart';

/// Keep a stable baseline until pending reviews settle: an aggregate cannot
/// reveal whether a timed-out upload is already included in the server count.
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
      // A pending review can make this response unusable; still consume errors.
      unawaited(response.then<void>((_) {}, onError: (Object _) {}));
      final boundary = await boundaryFuture;
      if (!current()) throw StateError('Deck count request expired');
      if (boundary != null) {
        final fetchedAt = clock().toUtc();
        try {
          final counts = await response;
          if (!current()) throw StateError('Deck count request expired');
          final accepted = await store.saveDeckCounts(
            counts,
            fetchedAt: fetchedAt,
            ownerScope: ownerScope,
            canWrite: current,
            boundary: boundary,
          );
          if (!current()) throw StateError('Deck count request expired');
          if (accepted) return counts;
        } catch (_) {
          if (!current()) rethrow;
          final snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
          if (!current()) throw StateError('Deck count request expired');
          if (snapshot == null) rethrow;
          return snapshot.counts;
        }
      }
    }
    final snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
    if (!current()) throw StateError('Deck count request expired');
    if (snapshot == null) throw StateError('Deck counts unavailable offline');
    return snapshot.counts;
  }
}

import 'local_review_store.dart';
import 'recall_api.dart';

/// Server aggregates remain the baseline. Local reviews only remove cards from
/// the due/new buckets until replay and a fresh server read replace the cache.
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
    ({Map<int, ({int due, int neu})> counts, DateTime fetchedAt})? snapshot;
    if (offline) {
      snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
    } else {
      final fetchedAt = clock().toUtc();
      try {
        final counts = await api.fetchDeckCounts();
        if (!current()) throw StateError('Deck count request expired');
        snapshot = (counts: counts, fetchedAt: fetchedAt);
        // Cache failures must not hide a successful server response.
        try {
          await store.saveDeckCounts(
            counts,
            fetchedAt: fetchedAt,
            ownerScope: ownerScope,
            canWrite: current,
          );
        } catch (_) {
          /* Disposable cache. */
        }
      } catch (_) {
        if (!current()) rethrow;
        snapshot = await store.loadDeckCounts(ownerScope: ownerScope);
        if (snapshot == null) rethrow;
      }
    }
    if (snapshot == null) throw StateError('Deck counts unavailable offline');
    final pending = await store.outbox(ownerScope: ownerScope);
    if (!current()) throw StateError('Deck count request expired');
    final counts = Map<int, ({int due, int neu})>.of(snapshot.counts);
    final seen = <int>{};
    for (final entry in pending) {
      final cardId = entry['card_id'];
      final deckId = entry['deck_id'];
      final state = entry['previous_state'];
      // Legacy outbox entries lack deck metadata. Never guess a deck or bucket.
      if (cardId is! int ||
          deckId is! int ||
          state is! int ||
          !seen.add(cardId)) {
        continue;
      }
      final count = counts[deckId];
      if (count == null) continue;
      final due = DateTime.tryParse(entry['previous_due'] as String? ?? '');
      counts[deckId] = (
        due: state != 0 && due != null && !due.isAfter(snapshot.fetchedAt)
            ? (count.due - 1).clamp(0, count.due)
            : count.due,
        neu: state == 0 ? (count.neu - 1).clamp(0, count.neu) : count.neu,
      );
    }
    return counts;
  }
}

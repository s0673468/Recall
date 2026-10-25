import '../data/list_feedback_api.dart';
import '../data/local_review_store.dart';
import '../data/recall_api.dart';
import '../domain/list_feedback.dart';
import '../domain/stats_models.dart';

/// A read-only list snapshot. Pending actions overlay cloud flags so an offline
/// like, dislike or withdrawal appears without changing review behavior.
class ListFeedbackService {
  final RecallApi api;
  final LocalReviewStore store;

  const ListFeedbackService({required this.api, required this.store});

  Future<Map<String, ListFeedback>> load({
    required Map<String, String> noteTags,
    List<ReviewLogEntry> reviewLog = const [],
  }) async {
    final owner = store.activeOwnerScope;
    Future<List<Map<String, dynamic>>> orEmpty(
      Future<List<Map<String, dynamic>>> Function() read,
    ) async {
      try {
        return await read();
      } catch (_) {
        return [];
      }
    }

    // Capture the outbox before the cloud read: an ACK during the request must
    // not make a local action disappear from this snapshot.
    final pending = await orEmpty(() => store.flagOutbox(ownerScope: owner));
    List<Map<String, dynamic>> flags;
    try {
      flags = await api.fetchListFeedbackFlags();
    } catch (_) {
      // Hidden-card IDs also include deletion flags and cannot prove dislike.
      flags = await orEmpty(() => store.likedFlags(ownerScope: owner));
    }
    if (store.activeOwnerScope != owner) return const {};
    final merged = [...flags];
    for (final flag in pending) {
      if (flag['op'] == 'dismiss') {
        final ids = {flag['client_id'], ...?flag['like_client_ids'] as List?};
        merged.removeWhere(
          (existing) =>
              existing['card_id'] == flag['card_id'] &&
              ids.contains(existing['client_id']),
        );
      } else {
        merged.add(flag);
      }
    }
    return ListFeedback.byNode(
      flags: merged,
      noteTags: noteTags,
      reviewLog: reviewLog,
    );
  }
}

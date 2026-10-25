import 'concept_attribution.dart';
import 'stats_models.dart';

/// Feedback on cards mapped to a primer through note metadata. A concept can
/// have both kinds of feedback; neither means the primer itself was rated.
class ListFeedback {
  final bool liked;
  final bool disliked;

  const ListFeedback({this.liked = false, this.disliked = false});

  static Map<String, ListFeedback> byNode({
    required List<Map<String, dynamic>> flags,
    required Map<String, String> noteTags,
    List<ReviewLogEntry> reviewLog = const [],
  }) {
    // Older cached likes have only a card ID. Use an existing review identity
    // when available; never fetch card content or guess from a title.
    final guidByCard = {
      for (final review in reviewLog)
        if (review.cardId != null && review.guid != null)
          review.cardId!: review.guid!,
    };
    final result = <String, ListFeedback>{};
    for (final flag in flags) {
      final reason = flag['reason'];
      if (reason != 'like' && reason != 'dislike') continue;
      final guid = flag['guid'] ?? guidByCard[flag['card_id']];
      for (final node in ConceptAttribution.nodeTags(noteTags[guid])) {
        final previous = result[node] ?? const ListFeedback();
        result[node] = ListFeedback(
          liked: previous.liked || reason == 'like',
          disliked: previous.disliked || reason == 'dislike',
        );
      }
    }
    return result;
  }
}

import 'stats_models.dart';

/// Pure rules for attributing reviewed notes to Recall concept nodes.
///
/// Study, remediation, reading, and stats all use this contract. Keeping it in
/// the domain layer prevents those features from depending on the Stats screen's
/// data-loading service just to interpret `node::<id>` tags.
abstract final class ConceptAttribution {
  static const String _nodeTagPrefix = 'node::';
  static const String _nodeNoneSentinel = 'none';

  /// Concept-node ids from a space-delimited `notes.tags` string,
  /// order-preserving and deduplicated, excluding the `node::none` sentinel.
  /// Mirrors `recall_signal.py`'s `node_tags` contract.
  static List<String> nodeTags(String? tags) {
    if (tags == null || tags.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final token in tags.split(RegExp(r'\s+'))) {
      if (!token.startsWith(_nodeTagPrefix)) continue;
      final id = token.substring(_nodeTagPrefix.length);
      if (id.isEmpty || id == _nodeNoneSentinel) continue;
      if (seen.add(id)) out.add(id);
    }
    return out;
  }

  /// Primers whose tagged cards have at least one review on [today]'s local
  /// device day.
  static List<ConceptPage> todayConceptPages({
    required List<ReviewLogEntry> reviewLog,
    required Map<String, String> noteTags,
    required List<ConceptPage> conceptPages,
    required DateTime today,
  }) {
    final targetDay = _dayOnly(today);
    final reviewedNodeIds = <String>{};
    for (final review in reviewLog) {
      if (_dayOnly(review.at) != targetDay) continue;
      final guid = review.guid;
      if (guid == null) continue;
      reviewedNodeIds.addAll(nodeTags(noteTags[guid]));
    }

    return [
      for (final page in conceptPages)
        if (reviewedNodeIds.contains(page.nodeId)) page,
    ]..sort((a, b) => a.title.compareTo(b.title));
  }

  static DateTime _dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

import 'local_day.dart';
import 'stats_models.dart';

/// Pure rules for attributing reviewed notes to Recall concept nodes.
///
/// Study, remediation, reading, and stats all use this contract. Keeping it in
/// the domain layer prevents those features from depending on the Stats screen's
/// data-loading service just to interpret `node::<id>` tags.
abstract final class ConceptAttribution {
  static const String _nodeTagPrefix = 'node::';
  static const String _nodeNoneSentinel = 'none';
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Module of the reading pages the weekly review synthesizes from German's
  /// ChatGPT and Claude study discussions. Their node ids start with
  /// [chatNodePrefix]; they carry no card tags.
  static const String chatModule = 'From your chats';
  static const String chatNodePrefix = 'chat-';

  /// Chat syntheses updated within the last [days], newest first.
  static List<ConceptPage> recentChatPages({
    required List<ConceptPage> conceptPages,
    required DateTime now,
    int days = 14,
  }) {
    final since = now.subtract(Duration(days: days));
    return [
      for (final page in conceptPages)
        if (page.nodeId.startsWith(chatNodePrefix) &&
            page.updatedAt.isAfter(since))
          page,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// Concept-node ids from a space-delimited `notes.tags` string,
  /// order-preserving and deduplicated, excluding the `node::none` sentinel.
  /// Mirrors `recall_signal.py`'s `node_tags` contract.
  static List<String> nodeTags(String? tags) {
    if (tags == null || tags.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final token in tags.split(_whitespace)) {
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
    final dayOf = LocalDayMemo();
    final reviewedNodeIds = <String>{};
    for (final review in reviewLog) {
      if (dayOf(review.at) != targetDay) continue;
      final guid = review.guid;
      if (guid == null) continue;
      reviewedNodeIds.addAll(nodeTags(noteTags[guid]));
    }

    return [
      for (final page in conceptPages)
        if (reviewedNodeIds.contains(page.nodeId)) page,
    ]..sort((a, b) => a.title.compareTo(b.title));
  }

  /// Primers whose tagged cards were reviewed on any of the last [days] local
  /// device days, today included. The most recently reviewed come first.
  static List<ConceptPage> recentConceptPages({
    required List<ReviewLogEntry> reviewLog,
    required Map<String, String> noteTags,
    required List<ConceptPage> conceptPages,
    required DateTime today,
    int days = 3,
  }) {
    final todayOnly = _dayOnly(today);
    final firstDay = DateTime(
      todayOnly.year,
      todayOnly.month,
      todayOnly.day - (days - 1),
    );
    final lastReviewed = <String, DateTime>{};
    final dayOf = LocalDayMemo();
    for (final review in reviewLog) {
      final day = dayOf(review.at);
      if (day.isBefore(firstDay) || day.isAfter(todayOnly)) continue;
      final guid = review.guid;
      if (guid == null) continue;
      for (final node in nodeTags(noteTags[guid])) {
        final seen = lastReviewed[node];
        if (seen == null || review.at.isAfter(seen)) {
          lastReviewed[node] = review.at;
        }
      }
    }

    return [
      for (final page in conceptPages)
        if (lastReviewed.containsKey(page.nodeId)) page,
    ]..sort((a, b) {
      final byDay = _dayOnly(
        lastReviewed[b.nodeId]!,
      ).compareTo(_dayOnly(lastReviewed[a.nodeId]!));
      return byDay != 0 ? byDay : a.title.compareTo(b.title);
    });
  }

  static DateTime _dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

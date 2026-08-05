import '../data/local_review_store.dart';
import '../data/recall_api.dart';
import '../domain/stats_models.dart';
import 'stats_service.dart';

/// The local data needed to turn queued node ids into readable primer rows.
/// Nothing in this record is written back to Supabase.
class RemediationData {
  final List<LocalRemediationItem> queue;
  final List<ConceptNodeInfo> conceptNodes;
  final List<ConceptPage> conceptPages;
  final List<ConceptPage> readTodayPages;

  const RemediationData({
    required this.queue,
    required this.conceptNodes,
    required this.conceptPages,
    required this.readTodayPages,
  });

  List<ConceptPage> get visiblePages => visibleRemediationPages(
    queue: queue,
    conceptNodes: conceptNodes,
    conceptPages: conceptPages,
    readTodayPages: readTodayPages,
  );
}

/// Loads the existing read/primer linkage alongside the private local queue.
class RemediationService {
  final RecallApi api;
  final LocalReviewStore store;

  const RemediationService({required this.api, required this.store});

  Future<RemediationData> load({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final results = await Future.wait<Object>([
      store.remediationQueue(now: at),
      api.fetchReviewLog(),
      api.fetchNoteTags(),
      api.fetchConceptNodes(),
      api.fetchConceptPages(),
    ]);
    final reviewLog = results[1] as List<ReviewLogEntry>;
    final noteTags = results[2] as Map<String, String>;
    final conceptPages = results[4] as List<ConceptPage>;
    return RemediationData(
      queue: results[0] as List<LocalRemediationItem>,
      conceptNodes: results[3] as List<ConceptNodeInfo>,
      conceptPages: conceptPages,
      readTodayPages: StatsService.todayConceptPages(
        reviewLog: reviewLog,
        noteTags: noteTags,
        conceptPages: conceptPages,
        today: at,
      ),
    );
  }
}

/// Resolves queue ids to actual primer pages, drops concepts already present
/// in today's read attribution, and preserves the queue's oldest-first order.
/// Missing node/page ids are intentionally ignored until the primer metadata
/// exists; the disposable queue itself remains local and harmless.
List<ConceptPage> visibleRemediationPages({
  required List<LocalRemediationItem> queue,
  required List<ConceptNodeInfo> conceptNodes,
  required List<ConceptPage> conceptPages,
  required List<ConceptPage> readTodayPages,
}) {
  final resolvedNodes = {for (final node in conceptNodes) node.nodeId};
  final pagesByNode = {for (final page in conceptPages) page.nodeId: page};
  final readToday = {for (final page in readTodayPages) page.nodeId};
  final seen = <String>{};
  final visible = <ConceptPage>[];
  for (final item in queue) {
    if (!seen.add(item.nodeId) || readToday.contains(item.nodeId)) continue;
    if (!resolvedNodes.contains(item.nodeId)) continue;
    final page = pagesByNode[item.nodeId];
    if (page == null) continue;
    visible.add(page);
    if (visible.length == LocalReviewStore.maxDailyRemediations) break;
  }
  return visible;
}

import '../data/recall_api.dart';
import '../domain/stats_models.dart';

/// Owns the Stats screen's data access (via [RecallApi]) plus the pure
/// transforms that shape it for the chart widgets. The transforms are static so
/// they can be unit-tested against fixtures with no Supabase in play.
class StatsService {
  final RecallApi api;
  const StatsService(this.api);

  static const int heatmapWeeks = 26;
  static const int forecastDays = 14;

  /// Interval (days) at or above which a card counts as "mature".
  static const int matureIntervalDays = 21;

  /// Concepts (node-retention) window + rank floor — mirror `metis
  /// recall-signal`: a fortnight of reviews, ranked only once a node clears the
  /// floor. Kept in sync with recall_signal.py's REVIEW_WINDOW_DAYS.
  static const int conceptWindowDays = 14;
  static const int conceptMinReviews = 4;

  /// The `node::none` sentinel is a "deliberately un-mapped" marker, never a
  /// real graph node — excluded from attribution entirely.
  static const String _nodeTagPrefix = 'node::';
  static const String _nodeNoneSentinel = 'none';

  Future<List<ReviewLogEntry>> loadReviewLog() =>
      api.fetchReviewLog(days: heatmapWeeks * 7 + 7);

  Future<List<DateTime>> loadDueDates() => api.fetchDueDates();

  Future<Map<String, String>> loadNoteTags() => api.fetchNoteTags();

  Future<List<ConceptNodeInfo>> loadConceptNodes() => api.fetchConceptNodes();

  static DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  // ── Heatmap ──

  /// A GitHub-style grid of daily review counts for the last [weeks] weeks,
  /// weekday-aligned (Sunday-started columns) and ending in the current week.
  /// Future days in the trailing partial week are present with count 0.
  static List<HeatmapDay> buildHeatmap(
    List<ReviewLogEntry> reviews, {
    required DateTime today,
    int weeks = heatmapWeeks,
  }) {
    final todayDay = dayOnly(today);
    // Sunday index (0=Sun … 6=Sat) — DateTime.weekday is 1=Mon … 7=Sun.
    final sundayOffset = todayDay.weekday % 7;
    final startOfWeek = todayDay.subtract(Duration(days: sundayOffset));
    final gridStart = startOfWeek.subtract(Duration(days: (weeks - 1) * 7));
    final totalDays = weeks * 7;

    final counts = <DateTime, int>{};
    for (final r in reviews) {
      final day = dayOnly(r.at);
      if (day.isBefore(gridStart)) continue;
      counts[day] = (counts[day] ?? 0) + 1;
    }
    final maxCount = counts.values.fold(0, (a, b) => a > b ? a : b);

    return [
      for (var i = 0; i < totalDays; i++)
        () {
          final date = gridStart.add(Duration(days: i));
          final count = counts[date] ?? 0;
          return HeatmapDay(
            date: date,
            count: count,
            level: heatmapLevel(count, maxCount),
          );
        }(),
    ];
  }

  /// Quantise a day's count into a 0–4 intensity bucket relative to the busiest
  /// day in the window.
  static int heatmapLevel(int count, int maxCount) {
    if (count <= 0) return 0;
    if (maxCount <= 1) return 4;
    final ratio = count / maxCount;
    return (1 + (ratio * 3).ceil()).clamp(1, 4);
  }

  // ── Due forecast ──

  /// Count of cards due on each of the next [days] local days. Overdue cards
  /// (and today's) roll into day 0; cards beyond the horizon are dropped.
  static List<ForecastDay> buildForecast(
    List<DateTime> dueDates, {
    required DateTime today,
    int days = forecastDays,
  }) {
    final todayDay = dayOnly(today);
    final counts = List<int>.filled(days, 0);
    for (final due in dueDates) {
      var index = dayOnly(due).difference(todayDay).inDays;
      if (index < 0) index = 0; // overdue → today's bucket
      if (index >= days) continue; // beyond the horizon
      counts[index] += 1;
    }
    return [
      for (var i = 0; i < days; i++)
        ForecastDay(
          date: todayDay.add(Duration(days: i)),
          index: i,
          count: counts[i],
        ),
    ];
  }

  // ── Retention ──

  /// True retention over [windowDays]: the share of reviews the card was
  /// recalled (rating ≥ Hard, i.e. not Again — Anki's convention), split into
  /// young/mature cohorts by the scheduled interval where derivable.
  static RetentionSummary computeRetention(
    List<ReviewLogEntry> reviews, {
    required DateTime now,
    int windowDays = 30,
  }) {
    final cutoff = now.subtract(Duration(days: windowDays));
    var total = 0, passed = 0;
    var youngTotal = 0, youngPassed = 0;
    var matureTotal = 0, maturePassed = 0;

    for (final r in reviews) {
      if (r.at.isBefore(cutoff)) continue;
      final ok = r.rating >= 2;
      total++;
      if (ok) passed++;
      final interval = r.intervalDays;
      if (interval == null) continue;
      if (interval >= matureIntervalDays) {
        matureTotal++;
        if (ok) maturePassed++;
      } else {
        youngTotal++;
        if (ok) youngPassed++;
      }
    }

    return RetentionSummary(
      windowDays: windowDays,
      total: total,
      passed: passed,
      youngTotal: youngTotal,
      youngPassed: youngPassed,
      matureTotal: matureTotal,
      maturePassed: maturePassed,
    );
  }

  // ── Concepts (METIS node retention) ──

  /// Concept-node ids from a space-delimited `notes.tags` string, order-preserving
  /// + deduped, excluding the `node::none` sentinel. Mirrors recall_signal.py's
  /// `node_tags`.
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

  /// Per-node Again-rate over the last [window] days, weakest-first — the Stats
  /// "Concepts" section. Semantics mirror `metis recall-signal` exactly:
  ///
  ///  * pass = rating ≥ 2, fail = rating 1 (Again);
  ///  * a note's reviews attribute to EVERY `node::<id>` tag it carries
  ///    (`node::none` excluded via [nodeTags]);
  ///  * only nodes with ≥ [minReviews] reviews in the window are ranked
  ///    (Again-rate descending); the rest are counted in `notEnoughData`;
  ///  * `coveredNodeCount` is every node with ≥ 1 review in the window (the
  ///    coverage numerator).
  ///
  /// [noteTags] maps note guid -> raw tags string. Reviews whose guid is absent
  /// from the map (untagged, or the log row predates guid capture) contribute to
  /// nothing. Pure — no I/O.
  static ({
    List<NodeRetention> ranked,
    int notEnoughData,
    int coveredNodeCount,
  })
  computeNodeRetention({
    required List<ReviewLogEntry> reviewLog,
    required Map<String, String> noteTags,
    required List<ConceptNodeInfo> conceptNodes,
    required DateTime now,
    int window = conceptWindowDays,
    int minReviews = conceptMinReviews,
  }) {
    final cutoff = dayOnly(now).subtract(Duration(days: window - 1));

    // guid -> node ids, parsed once from the tag strings.
    final guidNodes = <String, List<String>>{};
    noteTags.forEach((guid, tags) {
      final ids = nodeTags(tags);
      if (ids.isNotEmpty) guidNodes[guid] = ids;
    });

    final reviews = <String, int>{};
    final again = <String, int>{};
    for (final r in reviewLog) {
      if (dayOnly(r.at).isBefore(cutoff)) continue;
      final guid = r.guid;
      if (guid == null) continue;
      final ids = guidNodes[guid];
      if (ids == null) continue;
      final ok = r.rating >= 2; // Anki true-retention convention
      for (final nid in ids) {
        reviews[nid] = (reviews[nid] ?? 0) + 1;
        if (!ok) again[nid] = (again[nid] ?? 0) + 1;
      }
    }

    final info = {for (final c in conceptNodes) c.nodeId: c};
    final all = [
      for (final entry in reviews.entries)
        NodeRetention(
          nodeId: entry.key,
          title: info[entry.key]?.title,
          module: info[entry.key]?.module,
          reviews: entry.value,
          againCount: again[entry.key] ?? 0,
        ),
    ];

    final ranked = all.where((n) => n.reviews >= minReviews).toList()
      ..sort((a, b) {
        final byRate = b.againRate.compareTo(a.againRate); // weakest first
        if (byRate != 0) return byRate;
        final byVolume = b.reviews.compareTo(a.reviews); // more evidence first
        if (byVolume != 0) return byVolume;
        return a.nodeId.compareTo(b.nodeId); // stable tiebreak
      });

    return (
      ranked: ranked,
      notEnoughData: all.length - ranked.length,
      coveredNodeCount: all.length,
    );
  }

  // ── Headline tiles ──

  /// Recall% / streak / review-count over the last [windowDays] for the
  /// headline tiles (kept from Stats v1).
  static ({String recall, int reviews, int streak}) tileStats(
    List<ReviewLogEntry> reviews, {
    required DateTime today,
    int windowDays = 30,
  }) {
    final cutoff = dayOnly(today).subtract(Duration(days: windowDays));
    final windowed = reviews.where((r) => !dayOnly(r.at).isBefore(cutoff));
    final total = windowed.length;
    final retained = windowed.where((r) => r.rating >= 2).length;
    final recall = total == 0 ? '—' : '${(retained / total * 100).round()}%';
    final days = {for (final r in windowed) dayOnly(r.at)};
    return (recall: recall, reviews: total, streak: _streak(days, today));
  }

  static int _streak(Set<DateTime> days, DateTime today) {
    if (days.isEmpty) return 0;
    final todayDay = dayOnly(today);
    var cursor = days.contains(todayDay)
        ? todayDay
        : todayDay.subtract(const Duration(days: 1));
    if (!days.contains(cursor)) return 0;
    var n = 0;
    while (days.contains(cursor)) {
      n++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return n;
  }
}

import '../data/recall_api.dart';
import '../data/models.dart';
import '../domain/concept_attribution.dart';
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

  Future<List<ReviewLogEntry>> loadReviewLog() =>
      api.fetchReviewLog(days: heatmapWeeks * 7 + 7);

  Future<List<DateTime>> loadDueDates({Set<int>? includedDeckIds}) =>
      api.fetchDueDates(includedDeckIds: includedDeckIds);

  /// Stats describes the normal automatic workload. Optional curricula stay
  /// visible in Decks and directly reviewable, but do not inflate this chart.
  Future<List<DateTime>> loadAutomaticDueDates() async {
    final decks = await api.fetchDecks();
    return loadDueDates(includedDeckIds: automaticReviewDeckIds(decks));
  }

  Future<Map<String, String>> loadNoteTags() => api.fetchNoteTags();

  Future<List<ConceptNodeInfo>> loadConceptNodes() => api.fetchConceptNodes();

  Future<List<ConceptPage>> loadConceptPages() => api.fetchConceptPages();

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
    return (ratio * 4).ceil().clamp(1, 4);
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
  /// young/mature cohorts by the interval that was tested where derivable.
  static RetentionSummary computeRetention(
    List<ReviewLogEntry> reviews, {
    required DateTime now,
    int windowDays = 30,
  }) {
    final cutoff = dayOnly(now).subtract(Duration(days: windowDays));
    var total = 0, passed = 0;
    var youngTotal = 0, youngPassed = 0;
    var matureTotal = 0, maturePassed = 0;

    // The API orders rows, but keeping this transform pure and order-safe makes
    // it usable with cached or test fixtures too. The previous review remains
    // available even when it falls outside the retention window.
    final ordered = List<ReviewLogEntry>.from(reviews)
      ..sort((a, b) => a.at.compareTo(b.at));
    final previousAtByCard = <int, DateTime>{};
    final previousStateAfterByCard = <int, int?>{};

    for (final r in ordered) {
      final previousAt = r.cardId == null ? null : previousAtByCard[r.cardId!];
      final previousStateAfter = r.cardId == null
          ? null
          : previousStateAfterByCard[r.cardId!];
      if (r.cardId != null) {
        previousAtByCard[r.cardId!] = r.at;
        previousStateAfterByCard[r.cardId!] = r.stateAfter;
      }
      if (r.at.isBefore(cutoff)) continue;
      // Legacy rows may not carry state_after. Keep those rows visible. A real
      // lapse from review enters relearning (state_after=3), so rating 1 with
      // that state is counted. Without state_before the same row shape is also
      // possible for Again during relearning. A successful press can graduate
      // relearning back to state_after=2, which is likewise excluded when the
      // previous row is available. Rows without a derivable predecessor retain
      // the documented conservative over-count.
      final isReviewState =
          r.stateAfter == null ||
          (r.stateAfter == 2 && previousStateAfter != 3) ||
          (r.stateAfter == 3 && r.rating == 1 && previousStateAfter != 3);
      if (!isReviewState) continue;
      final ok = r.rating >= 2;
      total++;
      if (ok) passed++;
      // Young/mature is based on the interval the learner had to recall, not
      // the interval FSRS schedules after this press. Old rows without a card
      // id fall back to due_after-at for continuity.
      final testedInterval = previousAt == null
          ? null
          : r.at.difference(previousAt).inDays;
      final interval = testedInterval ?? r.intervalDays;
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

  /// Per-node Again-rate over the last [window] days, weakest-first — the Stats
  /// "Concepts" section. Semantics mirror `metis recall-signal` exactly:
  ///
  ///  * pass = rating ≥ 2, fail = rating 1 (Again);
  ///  * a note's reviews attribute to EVERY `node::<id>` tag it carries
  ///    (`node::none` excluded via [ConceptAttribution.nodeTags]);
  ///  * unresolved node IDs are ignored until their `concept_nodes` row syncs;
  ///  * only nodes with ≥ [minReviews] reviews in the window are ranked
  ///    (Again-rate descending); the rest are counted in `notEnoughData`;
  ///  * `coveredNodeCount` is every resolved node with ≥ 1 review in the window
  ///    (the coverage numerator).
  ///
  /// [noteTags] maps note guid -> raw tags string. Reviews whose guid is absent
  /// from the map (untagged, or the log row predates guid capture) contribute to
  /// nothing. Pure — no I/O.
  static ({List<NodeRetention> ranked, int notEnoughData, int coveredNodeCount})
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
      final ids = ConceptAttribution.nodeTags(tags);
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
        if (info.containsKey(entry.key))
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
    // Streak spans the whole log, not the recall window: building the day-set
    // from `windowed` capped it at windowDays + 1.
    final days = {for (final r in reviews) dayOnly(r.at)};
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

/// Plain data models for the Stats screen. All timestamps are **local** — the
/// service converts on the way out so grouping matches the streak/day
/// convention used elsewhere (a review at 23:30 local counts on that local day).
library;

/// One review, enriched beyond the old (at, rating) pair with the post-review
/// state and the scheduled next-due (for interval/maturity math).
class ReviewLogEntry {
  final String? guid; // note guid, for node-tag attribution (null on old rows)
  final DateTime at; // local
  final int rating; // 1=Again 2=Hard 3=Good 4=Easy
  final int? stateAfter; // 1=learning 2=review 3=relearning
  final DateTime? dueAfter; // local

  const ReviewLogEntry({
    this.guid,
    required this.at,
    required this.rating,
    this.stateAfter,
    this.dueAfter,
  });

  /// The scheduled interval this review produced, in whole days (null when the
  /// log row has no due_after).
  int? get intervalDays => dueAfter?.difference(at).inDays;
}

/// A single heatmap cell: a local calendar day, its review count, and an
/// intensity bucket 0–4 (0 = no reviews).
class HeatmapDay {
  final DateTime date; // local, day-only
  final int count;
  final int level; // 0..4

  const HeatmapDay({
    required this.date,
    required this.count,
    required this.level,
  });
}

/// One upcoming day in the due forecast. [index] 0 = today (with overdue rolled
/// in).
class ForecastDay {
  final DateTime date; // local, day-only
  final int index; // 0..(days-1)
  final int count;

  const ForecastDay({
    required this.date,
    required this.index,
    required this.count,
  });
}

/// True-retention over a window, split into young/mature cohorts when the log
/// carries enough due_after data to derive intervals.
class RetentionSummary {
  final int windowDays;
  final int total;
  final int passed; // rating >= 2 (not Again) — Anki's true-retention rule
  final int youngTotal;
  final int youngPassed;
  final int matureTotal;
  final int maturePassed;

  const RetentionSummary({
    required this.windowDays,
    required this.total,
    required this.passed,
    required this.youngTotal,
    required this.youngPassed,
    required this.matureTotal,
    required this.maturePassed,
  });

  bool get isEmpty => total == 0;

  /// Cohort split is only meaningful when some reviews carried an interval.
  bool get hasCohorts => (youngTotal + matureTotal) > 0;

  double? get overallRate => total == 0 ? null : passed / total;
  double? get youngRate => youngTotal == 0 ? null : youngPassed / youngTotal;
  double? get matureRate =>
      matureTotal == 0 ? null : maturePassed / matureTotal;
}

/// A METIS concept-graph node's display metadata, mirrored into the Recall cloud
/// (`concept_nodes` table) so a note's `node::<id>` tag resolves to a title +
/// module on the Stats screen. [nodeId] is the graph id (e.g. `m00-vector-geometry`).
class ConceptNodeInfo {
  final String nodeId;
  final String title;
  final String module;

  const ConceptNodeInfo({
    required this.nodeId,
    required this.title,
    required this.module,
  });
}

/// Per-node retention over the Concepts window: how a concept's tagged cards
/// fared. Mirrors `metis recall-signal`'s Again-rate — pass = rating ≥ 2,
/// fail = rating 1 (Again). [title]/[module] are null when the node carries a
/// tag but no `concept_nodes` row resolves it (fall back to the raw [nodeId]).
class NodeRetention {
  final String nodeId;
  final String? title;
  final String? module;
  final int reviews;
  final int againCount;

  const NodeRetention({
    required this.nodeId,
    required this.title,
    required this.module,
    required this.reviews,
    required this.againCount,
  });

  /// Share of reviews that were Again (rating 1) — the weakest-first rank key.
  /// 0 when there were no reviews (a node below the floor is grouped, not ranked).
  double get againRate => reviews == 0 ? 0 : againCount / reviews;
}

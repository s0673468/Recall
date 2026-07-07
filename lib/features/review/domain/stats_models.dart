/// Plain data models for the Stats screen. All timestamps are **local** — the
/// service converts on the way out so grouping matches the streak/day
/// convention used elsewhere (a review at 23:30 local counts on that local day).
library;

/// One review, enriched beyond the old (at, rating) pair with the post-review
/// state and the scheduled next-due (for interval/maturity math).
class ReviewLogEntry {
  final DateTime at; // local
  final int rating; // 1=Again 2=Hard 3=Good 4=Easy
  final int? stateAfter; // 1=learning 2=review 3=relearning
  final DateTime? dueAfter; // local

  const ReviewLogEntry({
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

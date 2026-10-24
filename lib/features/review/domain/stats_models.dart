/// Plain data models for the Stats screen. All timestamps are **local** — the
/// service converts on the way out so grouping matches the streak/day
/// convention used elsewhere (a review at 23:30 local counts on that local day).
library;

/// One review, enriched beyond the old (at, rating) pair with the post-review
/// state and the scheduled next-due (for interval/maturity math).
class ReviewLogEntry {
  final int? id;
  final String? clientEventId;
  final String? device;
  final int? cardId;
  final String? guid; // note guid, for node-tag attribution (null on old rows)
  final DateTime at; // local
  final int rating; // 1=Again 2=Hard 3=Good 4=Easy
  final int? stateAfter; // 1=learning 2=review 3=relearning
  final DateTime? dueAfter; // local

  const ReviewLogEntry({
    this.id,
    this.clientEventId,
    this.device,
    this.cardId,
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

/// A read-only primer for one concept-graph node. [bodyHtml] uses the same
/// light-HTML + inline-LaTeX format as a card face. [figureSvg] is the hero
/// figure drawn above the body; [extraFigures] are drawn inline after chosen
/// top-level paragraphs (see [ConceptExtraFigure]).
class ConceptPage {
  final String nodeId;
  final String title;
  final String bodyHtml;
  final String? figureSvg;
  final List<ConceptExtraFigure> extraFigures;
  final DateTime updatedAt;

  const ConceptPage({
    required this.nodeId,
    required this.title,
    required this.bodyHtml,
    this.figureSvg,
    this.extraFigures = const [],
    required this.updatedAt,
  });
}

/// One inline primer figure from `concept_pages.extra_figures` (migration 009).
///
/// [afterParagraph] is the 1-based top-level paragraph of the body the figure
/// follows; null means "after the body" (missing or invalid in the row).
class ConceptExtraFigure {
  /// Clients render at most this many extra figures per page.
  static const maxCount = 3;

  final String svg;
  final int? afterParagraph;

  const ConceptExtraFigure({required this.svg, this.afterParagraph});

  /// Parses the `extra_figures` JSON column defensively: a page must never
  /// fail or disappear because of it. A non-array (or null) value yields no
  /// figures; an element without a string `svg` starting with `<svg` is
  /// skipped; a missing or invalid `after_paragraph` (not an integer >= 1)
  /// places the figure after the body; only the first [maxCount] valid
  /// figures are kept, in array order.
  static List<ConceptExtraFigure> parseList(Object? raw) {
    if (raw is! List) return const [];
    final figures = <ConceptExtraFigure>[];
    for (final element in raw) {
      if (figures.length == maxCount) break;
      if (element is! Map) continue;
      final svg = element['svg'];
      if (svg is! String || !svg.trimLeft().startsWith('<svg')) continue;
      final after = element['after_paragraph'];
      figures.add(
        ConceptExtraFigure(
          svg: svg,
          afterParagraph: after is int && after >= 1 ? after : null,
        ),
      );
    }
    return List.unmodifiable(figures);
  }
}

/// Per-node retention over the Concepts window: how a concept's tagged cards
/// fared. Mirrors `metis recall-signal`'s Again-rate — pass = rating ≥ 2,
/// fail = rating 1 (Again). Only node IDs resolved by `concept_nodes` are
/// included, so coverage stays aligned with the synced concept graph.
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

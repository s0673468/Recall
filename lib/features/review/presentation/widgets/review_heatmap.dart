import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';

/// GitHub-style review-count heatmap. Days arrive Sunday-aligned in
/// chronological order (see [StatsService.buildHeatmap]), so column = index ~/ 7
/// and row = index % 7 forms the grid. Intensity shades use the shared muted activity colour.
class ReviewHeatmap extends StatelessWidget {
  final List<HeatmapDay> days;
  const ReviewHeatmap({super.key, required this.days});

  static const double _cell = 12;
  static const double _gap = 3;

  Color _levelColor(int level) {
    if (level <= 0) return UiColors.border.withValues(alpha: 0.6);
    const alphas = [0.28, 0.5, 0.72, 1.0];
    return UiColors.chartTeal.withValues(
      alpha: alphas[(level - 1).clamp(0, 3)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = days.fold(0, (a, d) => a + d.count);
    final weeks = (days.length / 7).ceil();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$total reviews over the last 26 weeks',
            style: const TextStyle(
              color: UiColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: UiSpacing.md),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true, // keep the most recent weeks in view
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var w = 0; w < weeks; w++)
                  Padding(
                    padding: const EdgeInsets.only(right: _gap),
                    child: Column(
                      children: [
                        for (var r = 0; r < 7; r++) _dayCell(w * 7 + r),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: UiSpacing.sm),
          _legend(),
        ],
      ),
    );
  }

  Widget _dayCell(int index) {
    if (index >= days.length) {
      return const SizedBox(width: _cell, height: _cell + _gap);
    }
    final day = days[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: _gap),
      child: Tooltip(
        message:
            '${day.date.year}-${day.date.month.toString().padLeft(2, '0')}-'
            '${day.date.day.toString().padLeft(2, '0')} · ${day.count}',
        child: Container(
          width: _cell,
          height: _cell,
          decoration: BoxDecoration(
            color: _levelColor(day.level),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _legend() {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: UiSpacing.xs,
      children: [
        const Text(
          'Less',
          style: TextStyle(color: UiColors.textMuted, fontSize: 10),
        ),
        const SizedBox(width: 4),
        for (var level = 0; level <= 4; level++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _levelColor(level),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        const SizedBox(width: 4),
        const Text(
          'More',
          style: TextStyle(color: UiColors.textMuted, fontSize: 10),
        ),
      ],
    );
  }
}

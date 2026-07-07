import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show scopedPanelColor;
import 'package:intl/intl.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';

/// Next-14-days due forecast as an fl_chart bar chart. Day 0 (today) includes
/// any overdue cards; the label reads "Today".
class DueForecastChart extends StatelessWidget {
  final List<ForecastDay> days;
  const DueForecastChart({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    final total = days.fold(0, (a, d) => a + d.count);
    final maxCount = days.fold(0, (a, d) => d.count > a ? d.count : a);
    final maxY = (maxCount <= 0 ? 1 : maxCount * 1.2);

    return Container(
      padding: const EdgeInsets.all(UiSpacing.md),
      decoration: BoxDecoration(
        color: scopedPanelColor(context),
        borderRadius: BorderRadius.circular(UiRadius.lg),
        border: Border.all(color: UiColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Due · next 14 days  ($total)',
            style: const TextStyle(
              color: UiColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UiSpacing.md),
          if (total == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UiSpacing.lg),
              child: Text(
                'Nothing scheduled in the next two weeks.',
                style: TextStyle(color: UiColors.textMuted),
              ),
            )
          else
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  minY: 0,
                  maxY: maxY.toDouble(),
                  alignment: BarChartAlignment.spaceAround,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: UiColors.border.withValues(alpha: 0.4),
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => UiColors.panelRaised,
                      getTooltipItem: (group, _, rod, _) {
                        final d = days[group.x.toInt()];
                        final label = d.index == 0
                            ? 'Today'
                            : DateFormat.MMMd().format(d.date);
                        return BarTooltipItem(
                          '$label · ${d.count}',
                          const TextStyle(
                            color: UiColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        maxIncluded: false,
                        getTitlesWidget: (value, meta) => Text(
                          value.toStringAsFixed(0),
                          style: const TextStyle(
                            color: UiColors.textMuted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final i = value.round();
                          if (i < 0 || i >= days.length) {
                            return const SizedBox.shrink();
                          }
                          if (i != 0 && i != days.length - 1 && i % 3 != 0) {
                            return const SizedBox.shrink();
                          }
                          final label = i == 0
                              ? 'Now'
                              : DateFormat.Md().format(days[i].date);
                          return Padding(
                            padding: const EdgeInsets.only(top: UiSpacing.xs),
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: UiColors.textMuted,
                                fontSize: 10,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (final d in days)
                      BarChartGroupData(
                        x: d.index,
                        barRods: [
                          BarChartRodData(
                            toY: d.count.toDouble(),
                            width: 8,
                            borderRadius: BorderRadius.circular(2),
                            color: d.index == 0
                                ? UiColors.primary
                                : UiColors.primary.withValues(alpha: 0.6),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

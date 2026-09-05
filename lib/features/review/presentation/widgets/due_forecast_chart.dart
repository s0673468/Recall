import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$total cards due over the next 14 days',
            style: const TextStyle(
              color: UiColors.textSecondary,
              fontSize: 13,
              height: 1.5,
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
            LayoutBuilder(
              builder: (context, constraints) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(10) / 10;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: math.max(constraints.maxWidth, 360 * textScale),
                    height: 180 + 28 * textScale,
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
                              reservedSize: math.max(
                                28,
                                maxCount.toString().length * 7 * textScale + 8,
                              ),
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
                              reservedSize: 28 * textScale,
                              getTitlesWidget: (value, meta) {
                                final i = value.round();
                                if (i < 0 || i >= days.length) {
                                  return const SizedBox.shrink();
                                }
                                if (i != 0 &&
                                    i != days.length - 1 &&
                                    (i % 3 != 0 || i >= days.length - 2)) {
                                  return const SizedBox.shrink();
                                }
                                final label = i == 0
                                    ? 'Now'
                                    : DateFormat.Md().format(days[i].date);
                                return Padding(
                                  padding: const EdgeInsets.only(
                                    top: UiSpacing.xs,
                                  ),
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
                                      : UiColors.chartTeal.withValues(
                                          alpha: 0.75,
                                        ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

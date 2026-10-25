import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';
import 'stats_chart_styles.dart';

/// Day zero is due now (including overdue). The following days have an
/// independent scale, so a backlog cannot flatten the daily forecast.
class DueForecastChart extends StatefulWidget {
  final List<ForecastDay> days;
  const DueForecastChart({super.key, required this.days});

  @override
  State<DueForecastChart> createState() => _DueForecastChartState();
}

class _DueForecastChartState extends State<DueForecastChart> {
  DateTime? _selected;

  @override
  Widget build(BuildContext context) {
    final now = widget.days.where((day) => day.index == 0).firstOrNull;
    final daily = widget.days.where((day) => day.index > 0).take(14).toList();
    final maximum = daily.fold(0, (n, day) => math.max(n, day.count));
    final selected = widget.days
        .where((day) => day.date == _selected)
        .firstOrNull;
    final description = widget.days
        .map((day) {
          final date = day.index == 0
              ? 'Today'
              : DateFormat.yMMMd().format(day.date);
          return '$date: ${day.count} ${day.count == 1 ? 'card' : 'cards'} due';
        })
        .join('; ');

    return Semantics(
      container: true,
      image: true,
      label: 'Due forecast. $description.',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatsChartReadout(
              placeholder:
                  'Now includes overdue cards. Daily scale: 0-0000000000 cards.',
              value:
                  'Now includes overdue cards. Daily scale: 0-$maximum cards.',
            ),
            const SizedBox(height: UiSpacing.xs),
            StatsChartReadout(
              key: const Key('forecast_readout'),
              placeholder: 'Choose a day to see its due count.',
              reservedValue: '2000-00-00 · 0000000000 cards due',
              value: selected == null
                  ? null
                  : '${DateFormat('yyyy-MM-dd').format(selected.date)} · ${selected.count} cards due',
            ),
            const SizedBox(height: UiSpacing.md),
            LayoutBuilder(
              builder: (context, constraints) {
                final nowColumn = Column(
                  key: const Key('forecast_now'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Now', style: Theme.of(context).textTheme.bodyMedium),
                    Text('${now?.count ?? 0}', style: StatsChartStyles.value),
                    const Text('due now', style: StatsChartStyles.caption),
                  ],
                );
                if (constraints.maxWidth > 600 &&
                    MediaQuery.textScalerOf(context).scale(12) <= 18) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          right: UiSpacing.lg,
                          bottom: UiSpacing.sm,
                        ),
                        // Counts must not change the daily grid's width when
                        // the loading placeholder resolves to a large backlog.
                        child: SizedBox(width: 112, child: nowColumn),
                      ),
                      Expanded(
                        child: _dailyGrid(
                          context,
                          daily,
                          maximum,
                          phone: false,
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    nowColumn,
                    const SizedBox(height: UiSpacing.md),
                    _dailyGrid(context, daily, maximum, phone: true),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _dailyGrid(
    BuildContext context,
    List<ForecastDay> days,
    int maximum, {
    required bool phone,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      // At large text sizes, use additional rows rather than shrink labels or
      // the 44dp targets. The normal phone layout is exactly two weeks.
      final labelMeasure = TextPainter(
        text: const TextSpan(text: 'Sep', style: StatsChartStyles.caption),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final minimumWidth = math.max(44.0, labelMeasure.width + 4);
      labelMeasure.dispose();
      final columns = math.min(
        phone ? 7 : 14,
        math.max(1, (constraints.maxWidth / minimumWidth).floor()),
      );
      final width = constraints.maxWidth / columns;
      return Wrap(
        key: const Key('forecast_daily_grid'),
        runSpacing: UiSpacing.md,
        children: [
          for (final day in days)
            SizedBox(
              width: width,
              child: InkWell(
                key: ValueKey('forecast_day_${day.index}'),
                onTap: () => setState(() => _selected = day.date),
                onFocusChange: (focused) {
                  if (focused) setState(() => _selected = day.date);
                },
                child: Column(
                  children: [
                    SizedBox(
                      height: 96,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          key: ValueKey('forecast_bar_${day.index}'),
                          width: 8,
                          height: maximum == 0
                              ? 2
                              : math.max(2, 96 * day.count / maximum),
                          decoration: BoxDecoration(
                            color: _selected == day.date
                                ? UiColors.primary
                                : StatsChartStyles.activity(
                                    day.count == 0 ? 0 : 4,
                                  ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: UiSpacing.sm),
                    Text(
                      '${DateFormat.MMM().format(day.date)}\n${day.date.day}',
                      key: ValueKey('forecast_date_${day.index}'),
                      textAlign: TextAlign.center,
                      style: StatsChartStyles.caption,
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

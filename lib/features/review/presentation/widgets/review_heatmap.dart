import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';
import 'stats_chart_styles.dart';

/// Sunday-aligned weeks, scaled to fill the column. A single keyboard stop
/// navigates the calendar: up/down = day, left/right = week.
class ReviewHeatmap extends StatefulWidget {
  final List<HeatmapDay> days;
  const ReviewHeatmap({super.key, required this.days});

  @override
  State<ReviewHeatmap> createState() => _ReviewHeatmapState();
}

class _ReviewHeatmapState extends State<ReviewHeatmap> {
  final _focus = FocusNode(debugLabel: 'Review activity calendar');
  int? _selected;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index < 0 || index >= widget.days.length || index == _selected) return;
    setState(() => _selected = index);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowLeft => -7,
      LogicalKeyboardKey.arrowRight => 7,
      _ => null,
    };
    if (delta == null || widget.days.isEmpty) return KeyEventResult.ignored;
    _select(((_selected ?? 0) + delta).clamp(0, widget.days.length - 1));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.days.fold(0, (n, day) => n + day.count);
    final weeks = (widget.days.length / 7).ceil();
    final selected = _selected != null && _selected! < widget.days.length
        ? widget.days[_selected!]
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatsChartReadout(
            placeholder: '0000000000 reviews over the last 26 weeks',
            value: '$total reviews over the last 26 weeks',
          ),
          const SizedBox(height: UiSpacing.md),
          Focus(
            key: const Key('heatmap_focus'),
            focusNode: _focus,
            onKeyEvent: _onKey,
            onFocusChange: (focused) {
              if (focused && _selected == null && widget.days.isNotEmpty) {
                _select(widget.days.length - 1);
              }
            },
            child: Semantics(
              hint:
                  'Use up and down arrows to move a day, left and right to move a week.',
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scaler = MediaQuery.textScalerOf(context);
                  final hintWidth = scaler.scale(12) + 8;
                  const gap = 3.0;
                  final columns = math.max(26, weeks);
                  final cell = weeks == 0
                      ? 0.0
                      : math.max(
                          0.0,
                          (constraints.maxWidth -
                                  hintWidth -
                                  gap * (columns - 1)) /
                              columns,
                        );
                  final pitch = cell + gap;
                  final monthHeight = scaler.scale(18);
                  // Weekday hints are two rows apart. Extra vertical space at
                  // large text sizes keeps them legible while cells stay square.
                  final rowGap = math.max(gap, monthHeight / 2 - cell);
                  final rowPitch = cell + rowGap;
                  final gridHeight = cell * 7 + rowGap * 6;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(left: hintWidth),
                        child: SizedBox(
                          height: monthHeight,
                          child: LayoutBuilder(
                            builder: (context, _) {
                              // Only place a label where it fits. At 200% text the
                              // labels spread out, without shrinking the text.
                              final labels = <Widget>[];
                              double nextLabelX = 0;
                              for (var w = 0; w < weeks; w++) {
                                final day = widget.days[w * 7].date;
                                final previous = w == 0
                                    ? null
                                    : widget.days[(w - 1) * 7].date;
                                if (previous != null &&
                                    previous.month == day.month) {
                                  continue;
                                }
                                final text = DateFormat.MMM().format(day);
                                final measure = TextPainter(
                                  text: TextSpan(
                                    text: text,
                                    style: StatsChartStyles.caption,
                                  ),
                                  textDirection: TextDirection.ltr,
                                  textScaler: scaler,
                                )..layout();
                                final x = w * pitch;
                                if (x >= nextLabelX &&
                                    x + measure.width <=
                                        constraints.maxWidth - hintWidth) {
                                  labels.add(
                                    Positioned(
                                      left: x,
                                      child: Text(
                                        text,
                                        style: StatsChartStyles.caption,
                                      ),
                                    ),
                                  );
                                  nextLabelX = x + measure.width + 8;
                                }
                                measure.dispose();
                              }
                              return Stack(children: labels);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: UiSpacing.xs),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: hintWidth,
                            height: gridHeight,
                            child: ExcludeSemantics(
                              child: Stack(
                                children: [
                                  for (final hint in [
                                    (1, 'M'),
                                    (3, 'W'),
                                    (5, 'F'),
                                  ])
                                    Positioned(
                                      top:
                                          (hint.$1 * rowPitch +
                                                  cell / 2 -
                                                  scaler.scale(18) / 2)
                                              .clamp(
                                                0,
                                                math.max(
                                                  0,
                                                  gridHeight - scaler.scale(18),
                                                ),
                                              ),
                                      child: Text(
                                        hint.$2,
                                        style: StatsChartStyles.caption,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: SizedBox(
                              key: const Key('heatmap_grid'),
                              height: gridHeight,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (var w = 0; w < weeks; w++) ...[
                                    if (w > 0) const SizedBox(width: gap),
                                    Semantics(
                                      image: true,
                                      label: _weekDescription(w),
                                      excludeSemantics: true,
                                      child: Column(
                                        children: [
                                          for (var r = 0; r < 7; r++) ...[
                                            if (r > 0) SizedBox(height: rowGap),
                                            _dayCell(w * 7 + r, cell),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: UiSpacing.sm),
          ExcludeSemantics(child: _legend()),
          const SizedBox(height: UiSpacing.sm),
          StatsChartReadout(
            key: const Key('heatmap_readout'),
            placeholder: 'Choose a day to see its review count.',
            reservedValue: '2000-00-00 · 0000000000 reviews',
            value: selected == null
                ? null
                : '${DateFormat('yyyy-MM-dd').format(selected.date)} · ${selected.count} reviews',
          ),
        ],
      ),
    );
  }

  String _weekDescription(int week) {
    final start = DateFormat.yMMMd().format(widget.days[week * 7].date);
    final counts = widget.days
        .skip(week * 7)
        .take(7)
        .map(
          (day) =>
              '${DateFormat.yMMMd().format(day.date)}: ${day.count} ${day.count == 1 ? 'review' : 'reviews'}',
        )
        .join('; ');
    return 'Review activity, week of $start. $counts.';
  }

  Widget _dayCell(int index, double cell) {
    if (index >= widget.days.length) return SizedBox.square(dimension: cell);
    final day = widget.days[index];
    return MouseRegion(
      onEnter: (_) => _select(index),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _select(index);
          _focus.requestFocus();
        },
        child: Container(
          key: ValueKey('heatmap_day_$index'),
          width: cell,
          height: cell,
          decoration: BoxDecoration(
            color: StatsChartStyles.activity(day.level),
            border: _selected == index
                ? Border.all(color: UiColors.primary, width: 2)
                : null,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _legend() => Wrap(
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    runSpacing: UiSpacing.xs,
    children: [
      const Text('Less', style: StatsChartStyles.caption),
      const SizedBox(width: 4),
      for (var level = 0; level <= 4; level++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: StatsChartStyles.activity(level),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      const SizedBox(width: 4),
      const Text('More', style: StatsChartStyles.caption),
    ],
  );
}

import 'package:flutter/material.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import '../../../../theme/ui_tokens.dart';

/// The four FSRS rating buttons, each labelled with the predicted next interval
/// (exactly the AnkiMobile affordance). Colours: Again=danger, Hard=warning,
/// Good=indigo, Easy=success.
class RatingBar extends StatelessWidget {
  final Map<Rating, DateTime> preview;
  final DateTime? previewAt;
  final ValueChanged<Rating> onRate;

  const RatingBar({
    super.key,
    required this.preview,
    this.previewAt,
    required this.onRate,
  });

  static const List<(Rating, String, Color)> _defs = [
    (Rating.again, 'Again', UiColors.danger),
    (Rating.hard, 'Hard', UiColors.warning),
    (Rating.good, 'Good', UiColors.primary),
    (Rating.easy, 'Easy', UiColors.success),
  ];

  @override
  Widget build(BuildContext context) {
    final now = (previewAt ?? DateTime.now()).toUtc();
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final useGrid = constraints.maxWidth < 340 || textScale > 1.3;
        if (!useGrid) {
          return Row(
            children: [
              for (final (rating, label, color) in _defs) ...[
                Expanded(child: _button(rating, label, color, now)),
                if (rating != Rating.easy) const SizedBox(width: UiSpacing.sm),
              ],
            ],
          );
        }

        final buttonWidth = (constraints.maxWidth - UiSpacing.sm) / 2;
        return Wrap(
          spacing: UiSpacing.sm,
          runSpacing: UiSpacing.sm,
          children: [
            for (final (rating, label, color) in _defs)
              SizedBox(
                width: buttonWidth,
                child: _button(rating, label, color, now),
              ),
          ],
        );
      },
    );
  }

  Widget _button(Rating rating, String label, Color color, DateTime now) {
    final due = preview[rating];
    final interval = due == null
        ? ''
        : humanizeRatingInterval(due.difference(now));
    final semanticsLabel = interval.isEmpty ? label : '$label, $interval';
    final primary = rating == Rating.good;
    return Semantics(
      label: semanticsLabel,
      button: true,
      excludeSemantics: true,
      child: FilledButton(
        onPressed: () => onRate(rating),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          backgroundColor: primary
              ? UiColors.primary
              : color.withValues(alpha: 0.14),
          foregroundColor: primary ? UiColors.canvas : color,
          padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UiRadius.md),
            side: BorderSide(
              color: primary ? UiColors.primary : color.withValues(alpha: 0.3),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (interval.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  interval,
                  style: TextStyle(
                    fontSize: 11,
                    color: primary
                        ? UiColors.canvas.withValues(alpha: 0.78)
                        : color.withValues(alpha: 0.85),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Format a future interval without shaving off its last partial unit.
///
/// The scheduler and widget read the clock a few milliseconds apart. Flooring
/// that duration made an exact 10-minute interval display as 9m and an exact
/// 6-day interval as 5d.
String humanizeRatingInterval(Duration d) {
  if (d <= Duration.zero) return 'now';

  final minutes =
      (d.inMicroseconds + Duration.microsecondsPerMinute - 1) ~/
      Duration.microsecondsPerMinute;
  if (minutes < 60) return '${minutes}m';

  final hours =
      (d.inMicroseconds + Duration.microsecondsPerHour - 1) ~/
      Duration.microsecondsPerHour;
  if (hours < 24) return '${hours}h';

  final days =
      (d.inMicroseconds + Duration.microsecondsPerDay - 1) ~/
      Duration.microsecondsPerDay;
  if (days < 30) return '${days}d';
  if (days < 365) return '${(days / 30).round()}mo';
  final years = days / 365;
  return '${years.toStringAsFixed(years.truncateToDouble() == years ? 0 : 1)}y';
}

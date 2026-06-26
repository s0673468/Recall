import 'package:flutter/material.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import '../../../../theme/ui_tokens.dart';

/// The four FSRS rating buttons, each labelled with the predicted next interval
/// (exactly the AnkiMobile affordance). Colours: Again=danger, Hard=warning,
/// Good=indigo, Easy=success.
class RatingBar extends StatelessWidget {
  final Map<Rating, DateTime> preview;
  final ValueChanged<Rating> onRate;

  const RatingBar({super.key, required this.preview, required this.onRate});

  static const List<(Rating, String, Color)> _defs = [
    (Rating.again, 'Again', UiColors.danger),
    (Rating.hard, 'Hard', UiColors.warning),
    (Rating.good, 'Good', UiColors.primary),
    (Rating.easy, 'Easy', UiColors.success),
  ];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    return Row(
      children: [
        for (final (rating, label, color) in _defs) ...[
          Expanded(child: _button(rating, label, color, now)),
          if (rating != Rating.easy) const SizedBox(width: UiSpacing.sm),
        ],
      ],
    );
  }

  Widget _button(Rating rating, String label, Color color, DateTime now) {
    final due = preview[rating];
    final interval = due == null ? '' : _humanize(due.difference(now));
    return FilledButton(
      onPressed: () => onRate(rating),
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.18),
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UiRadius.md),
          side: BorderSide(color: color.withValues(alpha: 0.35)),
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
                  color: color.withValues(alpha: 0.85),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _humanize(Duration d) {
  if (d.isNegative || d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  final days = d.inDays;
  if (days < 30) return '${days}d';
  if (days < 365) return '${(days / 30).round()}mo';
  final years = days / 365;
  return '${years.toStringAsFixed(years.truncateToDouble() == years ? 0 : 1)}y';
}

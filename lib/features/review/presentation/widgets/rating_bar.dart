import 'package:flutter/material.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import '../../../../theme/ui_tokens.dart';

/// The four recall ratings, without scheduler details competing with the answer.
class RatingBar extends StatelessWidget {
  final ValueChanged<Rating> onRate;
  final bool enabled;

  const RatingBar({super.key, required this.onRate, this.enabled = true});

  static const List<(Rating, String, Color)> _defs = [
    (Rating.again, 'Again', UiColors.danger),
    (Rating.hard, 'Hard', UiColors.warning),
    (Rating.good, 'Good', UiColors.primary),
    (Rating.easy, 'Easy', UiColors.success),
  ];

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final useGrid = constraints.maxWidth < 340 || textScale > 1.3;
        if (!useGrid) {
          return Row(
            children: [
              for (final (rating, label, color) in _defs) ...[
                Expanded(child: _button(rating, label, color)),
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
                child: _button(rating, label, color),
              ),
          ],
        );
      },
    );
  }

  Widget _button(Rating rating, String label, Color color) {
    final primary = rating == Rating.good;
    return Semantics(
      label: label,
      button: true,
      excludeSemantics: true,
      child: FilledButton(
        onPressed: enabled ? () => onRate(rating) : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          backgroundColor: primary ? UiColors.primary : UiColors.panel,
          foregroundColor: primary ? UiColors.canvas : color,
          padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UiRadius.md),
            side: BorderSide(
              color: primary ? UiColors.primary : UiColors.border,
            ),
          ),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

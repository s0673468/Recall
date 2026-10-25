import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/list_feedback.dart';

/// Passive status icons: keep the row's single navigation target and distinguish
/// the two states by shape and accessible text as well as color.
class ListFeedbackIndicator extends StatelessWidget {
  final ListFeedback feedback;

  const ListFeedbackIndicator({super.key, required this.feedback});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (feedback.liked)
        const Icon(
          Icons.thumb_up_outlined,
          size: 16,
          color: UiColors.primary,
          semanticLabel: 'Has liked cards',
        ),
      if (feedback.liked && feedback.disliked)
        const SizedBox(width: UiSpacing.xs),
      if (feedback.disliked)
        const Icon(
          Icons.thumb_down_outlined,
          size: 16,
          color: UiColors.textMuted,
          semanticLabel: 'Has disliked cards',
        ),
    ],
  );
}

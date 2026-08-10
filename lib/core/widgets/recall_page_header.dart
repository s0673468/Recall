import 'package:flutter/material.dart';

import '../../theme/ui_tokens.dart';

/// A consistent, quickly scannable heading for Recall's top-level tabs.
class RecallPageHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const RecallPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 24),
      ),
      const SizedBox(height: UiSpacing.xs),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: UiColors.textMuted,
          height: 1.35,
        ),
      ),
    ],
  );
}

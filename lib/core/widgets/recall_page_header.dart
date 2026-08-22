import 'package:flutter/material.dart';

import '../../theme/ui_tokens.dart';

/// A consistent, quickly scannable heading for Recall's top-level tabs.
class RecallPageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? eyebrow;
  final Widget? trailing;

  const RecallPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.eyebrow,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (eyebrow != null) ...[
              Text(
                eyebrow!.toUpperCase(),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: UiColors.primary,
                  letterSpacing: 1.1,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: UiSpacing.xs),
            ],
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontSize: 28, height: 1.05),
            ),
            const SizedBox(height: UiSpacing.sm),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: UiColors.textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: UiSpacing.md), trailing!],
    ],
  );
}

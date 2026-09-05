import 'package:flutter/material.dart';

import '../../theme/ui_tokens.dart';

/// A consistent, quickly scannable heading for Recall's top-level tabs.
class RecallPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? eyebrow;
  final Widget? trailing;

  const RecallPageHeader({
    super.key,
    required this.title,
    this.subtitle,
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
                eyebrow!,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: UiColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: UiSpacing.xs),
            ],
            Text(title, style: Theme.of(context).textTheme.headlineMedium),
            if (subtitle != null) ...[
              const SizedBox(height: UiSpacing.xs),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: UiColors.textMuted,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: UiSpacing.md), trailing!],
    ],
  );
}

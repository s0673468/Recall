import 'package:flutter/material.dart';

import '../../theme/ui_tokens.dart';

/// Recall's quiet surface grammar.
///
/// A top-level screen gets at most one [RecallHeroPanel]. Supporting controls
/// use [RecallSectionCard], repeated peers use [RecallMetricStrip] or
/// [RecallListGroup], and ordinary headings remain unboxed.
class RecallHeroPanel extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final String? semanticsLabel;

  const RecallHeroPanel({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(UiSpacing.lg),
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    final panel = Container(
      decoration: buildHeroPanelDecoration(),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap, child: content),
            ),
    );
    return semanticsLabel == null
        ? panel
        : Semantics(label: semanticsLabel, button: onTap != null, child: panel);
  }
}

class RecallSectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const RecallSectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(UiSpacing.lg),
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: buildPanelDecoration(),
    padding: padding,
    child: child,
  );
}

class RecallSectionLabel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const RecallSectionLabel({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: UiSpacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: UiColors.textMuted),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class RecallMetric {
  final String label;
  final String value;
  final Color? color;

  const RecallMetric(this.label, this.value, {this.color});
}

/// Compact peer metrics separated by rules rather than individual cards.
class RecallMetricStrip extends StatelessWidget {
  final List<RecallMetric> metrics;

  const RecallMetricStrip({super.key, required this.metrics});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border.symmetric(
        horizontal: BorderSide(color: UiColors.borderSubtle),
      ),
    ),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0)
              const VerticalDivider(
                width: 1,
                thickness: 1,
                color: UiColors.borderSubtle,
              ),
            Expanded(child: _MetricTile(metric: metrics[i])),
          ],
        ],
      ),
    ),
  );
}

class _MetricTile extends StatelessWidget {
  final RecallMetric metric;

  const _MetricTile({required this.metric});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: UiSpacing.xs,
      vertical: UiSpacing.md,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            metric.value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: metric.color ?? UiColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          metric.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: UiColors.textMuted,
            fontSize: 11,
          ),
        ),
      ],
    ),
  );
}

class RecallStatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const RecallStatusPill({
    super.key,
    required this.label,
    this.color = UiColors.textSecondary,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
      ] else ...[
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
      ],
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ),
    ],
  );
}

class RecallListGroup extends StatelessWidget {
  final List<Widget> children;

  const RecallListGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border.symmetric(horizontal: BorderSide(color: UiColors.border)),
    ),
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: UiColors.borderSubtle),
          children[i],
        ],
      ],
    ),
  );
}

class RecallListRow extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const RecallListRow({
    super.key,
    this.icon,
    this.iconColor = UiColors.textMuted,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 0,
            vertical: UiSpacing.sm,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: iconColor, size: 20),
                const SizedBox(width: UiSpacing.sm),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: UiColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: UiColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: UiSpacing.sm),
                trailing!,
              ],
              const SizedBox(width: UiSpacing.xs),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: UiColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class RecallStatePanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const RecallStatePanel({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => RecallHeroPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: UiColors.primary, size: 30),
        const SizedBox(height: UiSpacing.md),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: UiSpacing.xs),
        Text(
          message,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: UiColors.textMuted),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: UiSpacing.lg),
          FilledButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ],
    ),
  );
}

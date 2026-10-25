import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';

/// Stats uses the same numeric rhythm and activity ramp in every section.
abstract final class StatsChartStyles {
  static const figures = [FontFeature.tabularFigures()];
  static const caption = TextStyle(
    color: UiColors.textMuted,
    fontSize: 12,
    height: 1.5,
    fontFeatures: figures,
  );
  static const value = TextStyle(
    color: UiColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.3,
    fontFeatures: figures,
  );

  static Color activity(int level) => level <= 0
      ? UiColors.panelRaised
      : UiColors.chartTeal.withValues(
          alpha: const [0.28, 0.44, 0.60, 0.75][(level - 1).clamp(0, 3)],
        );

  static TextTheme tabular(TextTheme text) => TextTheme(
    displayLarge: text.displayLarge?.copyWith(fontFeatures: figures),
    displayMedium: text.displayMedium?.copyWith(fontFeatures: figures),
    displaySmall: text.displaySmall?.copyWith(fontFeatures: figures),
    headlineLarge: text.headlineLarge?.copyWith(fontFeatures: figures),
    headlineMedium: text.headlineMedium?.copyWith(fontFeatures: figures),
    headlineSmall: text.headlineSmall?.copyWith(fontFeatures: figures),
    titleLarge: text.titleLarge?.copyWith(fontFeatures: figures),
    titleMedium: text.titleMedium?.copyWith(fontFeatures: figures),
    titleSmall: text.titleSmall?.copyWith(fontFeatures: figures),
    bodyLarge: text.bodyLarge?.copyWith(fontFeatures: figures),
    bodyMedium: text.bodyMedium?.copyWith(fontFeatures: figures),
    bodySmall: text.bodySmall?.copyWith(fontFeatures: figures),
    labelLarge: text.labelLarge?.copyWith(fontFeatures: figures),
    labelMedium: text.labelMedium?.copyWith(fontFeatures: figures),
    labelSmall: text.labelSmall?.copyWith(fontFeatures: figures),
  );
}

/// Both strings take part in layout, so selection never moves the chart.
/// The reserved text wraps naturally with the user's text size.
class StatsChartReadout extends StatelessWidget {
  final String placeholder;
  final String? value;
  final String? reservedValue;
  const StatsChartReadout({
    super.key,
    required this.placeholder,
    this.value,
    this.reservedValue,
  });

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.centerLeft,
    children: [
      ExcludeSemantics(
        child: Opacity(
          opacity: 0,
          child: Text(placeholder, style: StatsChartStyles.caption),
        ),
      ),
      // Reserve a full date and count as well as the prompt at every width.
      if (reservedValue != null)
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(reservedValue!, style: StatsChartStyles.caption),
          ),
        ),
      Text(value ?? placeholder, style: StatsChartStyles.caption),
    ],
  );
}

/// Keeps the exact final geometry while exposing a single loading summary.
class StatsSkeleton extends StatelessWidget {
  final Widget child;
  final int columns;
  const StatsSkeleton({super.key, required this.child, this.columns = 1});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ExcludeFocus(
      child: IgnorePointer(
        child: Stack(
          children: [
            Opacity(opacity: 0, child: child),
            Positioned.fill(
              child: Row(
                children: [
                  for (var i = 0; i < columns; i++) ...[
                    if (i > 0) const SizedBox(width: UiSpacing.md),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: UiColors.panelRaised,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

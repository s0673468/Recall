import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';

/// True retention over a chosen window, with the interval cohorts available
/// when the reader wants the underlying detail.
class RetentionPanel extends StatelessWidget {
  final RetentionSummary summary;
  final int windowDays;
  final ValueChanged<int> onWindowChanged;
  final bool hero;

  const RetentionPanel({
    super.key,
    required this.summary,
    required this.windowDays,
    required this.onWindowChanged,
    this.hero = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UiSpacing.md,
          runSpacing: UiSpacing.xs,
          children: [
            Text(
              'True retention',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            DropdownButton<int>(
              key: const Key('recall_retention_window'),
              value: windowDays,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(UiRadius.md),
              style: Theme.of(context).textTheme.bodySmall,
              items: const [
                DropdownMenuItem(value: 30, child: Text('30 days')),
                DropdownMenuItem(value: 90, child: Text('90 days')),
              ],
              onChanged: (window) {
                if (window != null) onWindowChanged(window);
              },
            ),
          ],
        ),
        const SizedBox(height: UiSpacing.md),
        if (summary.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: UiSpacing.md),
            child: Text(
              'No reviews in this window yet.',
              style: TextStyle(color: UiColors.textMuted),
            ),
          )
        else ...[
          _overall(context),
          const SizedBox(height: UiSpacing.sm),
          ExpansionTile(
            key: const PageStorageKey('recall_retention_cohorts'),
            maintainState: true,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: UiSpacing.sm),
            title: Text(
              'Young and mature cards',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            children: [
              if (summary.hasCohorts)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow =
                        constraints.maxWidth < 320 ||
                        MediaQuery.textScalerOf(context).scale(14) > 18;
                    final cohorts = [
                      _cohort(
                        context,
                        'Young',
                        summary.youngRate,
                        summary.youngTotal,
                      ),
                      _cohort(
                        context,
                        'Mature',
                        summary.matureRate,
                        summary.matureTotal,
                      ),
                    ];
                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: cohorts,
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final cohort in cohorts) Expanded(child: cohort),
                      ],
                    );
                  },
                )
              else
                const Padding(
                  padding: EdgeInsets.only(bottom: UiSpacing.sm),
                  child: Text(
                    'Young/mature split needs more interval history.',
                    style: TextStyle(color: UiColors.textMuted),
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _overall(BuildContext context) {
    final rate = summary.overallRate ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            '${(rate * 100).round()}%',
            style: TextStyle(
              color: UiColors.textPrimary,
              fontSize: hero ? 64 : 40,
              fontWeight: FontWeight.w400,
              height: 1.1,
              letterSpacing: -1.5,
            ),
          ),
        ),
        const SizedBox(height: UiSpacing.sm),
        Text(
          '${summary.passed} of ${summary.total} scheduled reviews remembered.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
        ),
        const SizedBox(height: UiSpacing.lg),
        ClipRRect(
          borderRadius: BorderRadius.circular(UiRadii.pill),
          child: LinearProgressIndicator(
            key: const Key('recall_retention_meter'),
            value: rate.clamp(0, 1),
            minHeight: 4,
            backgroundColor: UiColors.border,
            color: UiColors.chartTeal,
            semanticsLabel: 'True retention',
          ),
        ),
      ],
    );
  }

  Widget _cohort(BuildContext context, String label, double? rate, int total) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: UiSpacing.xs),
            Text(
              rate == null ? '—' : '${(rate * 100).round()}%',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '$total reviews',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
}

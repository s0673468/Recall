import 'package:flutter/material.dart';
import 'package:health_anki_flutter/vendored/health_flutter_shared.dart' show UiScore;

import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';

/// True-retention panel with a 30/90-day window toggle and, when the log
/// carries enough interval data, a young vs mature split.
class RetentionPanel extends StatelessWidget {
  final RetentionSummary summary;
  final int windowDays;
  final ValueChanged<int> onWindowChanged;

  const RetentionPanel({
    super.key,
    required this.summary,
    required this.windowDays,
    required this.onWindowChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UiSpacing.md),
      decoration: BoxDecoration(
        color: UiColors.panel,
        borderRadius: BorderRadius.circular(UiRadii.group),
        border: Border.all(color: UiColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'True retention',
                  style: TextStyle(
                    color: UiColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 30, label: Text('30d')),
                  ButtonSegment(value: 90, label: Text('90d')),
                ],
                selected: {windowDays},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelectionChanged: (s) => onWindowChanged(s.first),
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
            _overall(),
            if (summary.hasCohorts) ...[
              const SizedBox(height: UiSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _cohort(
                      'Young',
                      summary.youngRate,
                      summary.youngTotal,
                    ),
                  ),
                  const SizedBox(
                    height: 56,
                    child: VerticalDivider(color: UiColors.borderSubtle),
                  ),
                  Expanded(
                    child: _cohort(
                      'Mature',
                      summary.matureRate,
                      summary.matureTotal,
                    ),
                  ),
                ],
              ),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: UiSpacing.sm),
                child: Text(
                  'Young/mature split needs more interval history.',
                  style: TextStyle(color: UiColors.textMuted, fontSize: 11),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _overall() {
    final rate = summary.overallRate ?? 0;
    final color = UiScore.ratioTier(rate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${(rate * 100).round()}%',
              style: TextStyle(
                color: color,
                fontFamily: 'monospace',
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: UiSpacing.sm),
            Expanded(
              child: Text(
                'recalled · ${summary.passed}/${summary.total} reviews',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: UiSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(UiRadii.pill),
          child: LinearProgressIndicator(
            key: const Key('recall_retention_meter'),
            value: rate.clamp(0, 1),
            minHeight: 6,
            backgroundColor: UiColors.secondary,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _cohort(String label, double? rate, int total) {
    final value = rate == null ? '—' : '${(rate * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: UiSpacing.sm,
        horizontal: UiSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: rate == null
                  ? UiColors.textMuted
                  : UiScore.ratioTier(rate),
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            '$total reviews',
            style: const TextStyle(color: UiColors.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

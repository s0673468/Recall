import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show scopedPanelColor;

import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../data/models.dart';
import '../widgets/card_face.dart';
import '../widgets/rating_bar.dart';

class StudyScreen extends StatelessWidget {
  final ReviewController controller;

  /// Opens the settings screen from the header gear. Null hides the gear.
  final VoidCallback? onOpenSettings;

  const StudyScreen({super.key, required this.controller, this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.state;

        if (s.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.error != null && s.queue.isEmpty) {
          return _Message(
            icon: Icons.cloud_off_outlined,
            title: 'Could not load',
            subtitle: s.error!,
            action: 'Retry',
            onAction: controller.refresh,
          );
        }
        if (s.isDone) {
          final n = s.reviewedThisSession;
          return _Message(
            icon: Icons.check_circle_outline,
            title: 'All caught up',
            subtitle: n > 0
                ? 'Reviewed $n ${n == 1 ? 'card' : 'cards'} this session.'
                : 'Nothing due right now.',
            action: 'Reload',
            onAction: controller.refresh,
          );
        }

        final card = s.current!;
        final style = Theme.of(context).textTheme.titleLarge!.copyWith(
          color: UiColors.textPrimary,
          height: 1.4,
          fontWeight: FontWeight.w500,
        );

        return Column(
          children: [
            _Header(
              due: s.dueRemaining,
              neu: s.newRemaining,
              session: s.reviewedThisSession,
              offline: s.offline,
              pendingSync: s.pendingSync,
              onOpenSettings: onOpenSettings,
            ),
            const SizedBox(height: UiSpacing.sm),
            Expanded(
              child: _CardPanel(card: card, showBack: s.showBack, style: style),
            ),
            const SizedBox(height: UiSpacing.md),
            if (s.showBack)
              RatingBar(
                preview: controller.previewCurrent(),
                onRate: controller.rate,
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: controller.flip,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
                  ),
                  child: const Text('Show answer'),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final int due;
  final int neu;
  final int session;
  final bool offline;
  final int pendingSync;
  final VoidCallback? onOpenSettings;
  const _Header({
    required this.due,
    required this.neu,
    required this.session,
    required this.offline,
    required this.pendingSync,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _pill('$due due', UiColors.primary),
        const SizedBox(width: UiSpacing.xs),
        _pill('$neu new', UiColors.chartBlue),
        if (offline) ...[
          const SizedBox(width: UiSpacing.xs),
          _pill('offline', UiColors.warning),
        ] else if (pendingSync > 0) ...[
          const SizedBox(width: UiSpacing.xs),
          _pill('$pendingSync syncing', UiColors.textMuted),
        ],
        const Spacer(),
        Text(
          '$session done',
          style: const TextStyle(color: UiColors.textMuted, fontSize: 13),
        ),
        if (onOpenSettings != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Settings',
            icon: const Icon(
              Icons.settings_outlined,
              size: 20,
              color: UiColors.textMuted,
            ),
            onPressed: onOpenSettings,
          ),
      ],
    );
  }

  Widget _pill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: UiSpacing.sm, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(UiRadii.pill),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

class _CardPanel extends StatelessWidget {
  final ReviewCard card;
  final bool showBack;
  final TextStyle style;
  const _CardPanel({
    required this.card,
    required this.showBack,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UiSpacing.lg),
      decoration: BoxDecoration(
        color: scopedPanelColor(context),
        borderRadius: BorderRadius.circular(UiRadius.xl),
        border: Border.all(color: UiColors.border),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: UiSpacing.sm),
            CardFace(
              html: card.front,
              hasLatex: card.hasLatex,
              latexSvg: card.latexSvg,
              cacheKey: '${card.id}:front',
              style: style,
            ),
            if (showBack) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UiSpacing.lg),
                child: Divider(color: UiColors.border, height: 1),
              ),
              CardFace(
                html: card.back,
                hasLatex: card.hasLatex,
                latexSvg: card.latexSvg,
                cacheKey: '${card.id}:back',
                style: style.copyWith(
                  color: UiColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
            const SizedBox(height: UiSpacing.sm),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? action;
  final VoidCallback? onAction;
  const _Message({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UiSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: UiColors.primary),
            const SizedBox(height: UiSpacing.md),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: UiSpacing.sm),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: UiColors.textMuted),
            ),
            if (action != null) ...[
              const SizedBox(height: UiSpacing.lg),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

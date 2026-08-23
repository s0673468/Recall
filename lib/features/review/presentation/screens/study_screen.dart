import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../../../core/platform/recall_platform.dart';
import '../../../../core/widgets/recall_motion.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../application/backlog_catch_up.dart';
import '../../application/review_controller.dart';
import '../../data/local_review_store.dart';
import '../../data/models.dart';
import '../../data/recall_api.dart';
import '../widgets/card_face.dart';
import '../widgets/rating_bar.dart';
import '../widgets/remediation_rows.dart';

class StudyScreen extends StatelessWidget {
  final ReviewController controller;
  final RecallApi? api;
  final LocalReviewStore? store;

  /// Opens the settings screen from the header gear. Null hides the gear.
  final VoidCallback? onOpenSettings;
  final bool? nativeIos;

  const StudyScreen({
    super.key,
    required this.controller,
    this.api,
    this.store,
    this.onOpenSettings,
    this.nativeIos,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.state;
        // Hidden while nothing is undoable AND while an undo is completing
        // (rate() is blocked then too — nothing may interleave the restore).
        final undoable = controller.canUndo && !controller.undoInFlight;

        if (s.loading) {
          return const RecallMotionSwap(
            child: Center(
              key: ValueKey('study_loading'),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (s.error != null && s.queue.isEmpty) {
          return RecallMotionSwap(
            child: _Message(
              key: const ValueKey('study_error'),
              icon: Icons.cloud_off_outlined,
              title: 'Could not load',
              subtitle: s.error!,
              action: 'Retry',
              onAction: controller.refresh,
            ),
          );
        }
        if (s.isDone) {
          final n = s.reviewedThisSession;
          if (s.catchUp.isActive && s.catchUp.dueCount > 0) {
            return RecallMotionSwap(
              child: _Message(
                key: const ValueKey('study_catch_up_paused'),
                icon: Icons.pause_circle_outline,
                title: 'Catch-up paused',
                subtitle:
                    'Reviewed $n ${n == 1 ? 'card' : 'cards'} this session. '
                    'The daily catch-up limit is ${s.catchUp.dailyCap}. '
                    'Resume tomorrow.',
                action: 'Reload',
                onAction: controller.refresh,
                secondaryAction: undoable ? 'Undo last rating' : null,
                onSecondaryAction: undoable ? controller.undo : null,
              ),
            );
          }
          final reviewedLine = n > 0
              ? 'Reviewed $n ${n == 1 ? 'card' : 'cards'} this session.'
              : 'Nothing due right now.';
          // "Keep going" pulls a bonus batch (cards due in the next 24h +
          // unseen new cards). It hides once a fetch came back empty, and
          // needs a connection — the just-made ratings must sync first.
          final subtitle = s.aheadExhausted
              ? '$reviewedLine Nothing more within the next day.'
              : s.offline
              ? '$reviewedLine Bonus cards need a connection.'
              : reviewedLine;
          final canKeepGoing = !s.aheadExhausted && !s.offline;
          return RecallMotionSwap(
            child: ListView(
              key: const ValueKey('study_done'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(UiSpacing.lg),
              children: [
                _Message(
                  icon: Icons.check_circle_outline,
                  title: 'All caught up',
                  subtitle: subtitle,
                  action: canKeepGoing ? 'Keep going' : 'Reload',
                  onAction: canKeepGoing
                      ? controller.keepGoing
                      : controller.refresh,
                  // A mis-tap on the session's last card lands here — keep it
                  // recoverable (undo survives until the queue is reloaded).
                  secondaryAction: undoable
                      ? 'Undo last rating'
                      : (canKeepGoing ? 'Reload' : null),
                  onSecondaryAction: undoable
                      ? controller.undo
                      : (canKeepGoing ? controller.refresh : null),
                ),
                if (api != null && store != null) ...[
                  const SizedBox(height: UiSpacing.lg),
                  RemediationSection(
                    api: api!,
                    store: store!,
                    revision: controller.remediationRevision,
                  ),
                ],
              ],
            ),
          );
        }

        final card = s.current!;
        final style = Theme.of(context).textTheme.titleLarge!.copyWith(
          color: UiColors.textPrimary,
          height: 1.4,
          fontWeight: FontWeight.w400,
        );

        final catchUp = AnimatedSize(
          duration: RecallMotion.duration(context),
          curve: RecallMotion.curve,
          alignment: Alignment.topCenter,
          child: RecallMotionSwap(
            duration: RecallMotion.quick,
            child: s.catchUp.shouldOffer
                ? _CatchUpBanner(
                    key: const ValueKey('study_catch_up_offer'),
                    plan: s.catchUp,
                    onStart: controller.startCatchUp,
                    onShowAll: controller.showAll,
                  )
                : s.catchUp.isActive
                ? _CatchUpProgress(
                    key: const ValueKey('study_catch_up_progress'),
                    plan: s.catchUp,
                  )
                : const SizedBox(key: ValueKey('study_catch_up_hidden')),
          ),
        );
        final header = _Header(
          due: s.dueRemaining,
          neu: s.newRemaining,
          session: s.reviewedThisSession,
          offline: s.offline,
          pendingSync: s.pendingSync,
          onUndo: undoable ? controller.undo : null,
          // Flagging is independent of the review flow and of undo — it only
          // reports the current card, so it is live whenever a card is shown.
          onFlag: () => _showFlagSheet(
            context,
            controller,
            nativeIos: nativeIos ?? recallRunsAsNativeIos(),
          ),
          onOpenSettings: onOpenSettings,
        );
        final cardPanel = _CardPanel(
          card: card,
          showBack: s.showBack,
          style: style,
        );
        final actions = RecallMotionSwap(
          duration: RecallMotion.quick,
          travel: 0,
          child: s.showBack
              ? RatingBar(
                  key: const ValueKey('study_rating_bar'),
                  preview: controller.previewCurrent(),
                  previewAt: controller.previewCurrentAt,
                  onRate: controller.rate,
                  enabled: !controller.rateInFlight,
                )
              : SizedBox(
                  key: const ValueKey('study_show_answer'),
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: controller.flip,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: UiSpacing.md,
                      ),
                    ),
                    child: const Text('Show answer'),
                  ),
                ),
        );
        final accessibleScroll =
            MediaQuery.textScalerOf(context).scale(1) > 1.3;

        return RecallMotionSwap(
          child: accessibleScroll
              ? ListView(
                  key: ValueKey('study_card_${card.id}'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    catchUp,
                    header,
                    const SizedBox(height: UiSpacing.sm),
                    SizedBox(height: 260, child: cardPanel),
                    const SizedBox(height: UiSpacing.md),
                    actions,
                    const SizedBox(height: UiSpacing.sm),
                  ],
                )
              : Column(
                  key: ValueKey('study_card_${card.id}'),
                  children: [
                    catchUp,
                    header,
                    const SizedBox(height: UiSpacing.sm),
                    Expanded(child: cardPanel),
                    const SizedBox(height: UiSpacing.md),
                    actions,
                  ],
                ),
        );
      },
    );
  }
}

class _CatchUpBanner extends StatelessWidget {
  final CatchUpView plan;
  final VoidCallback onStart;
  final VoidCallback onShowAll;

  const _CatchUpBanner({
    super.key,
    required this.plan,
    required this.onStart,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UiSpacing.sm),
      child: RecallSectionCard(
        key: const Key('recall_catch_up_banner'),
        padding: const EdgeInsets.all(UiSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Large due backlog',
              style: TextStyle(
                color: UiColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UiSpacing.xs),
            Text(
              '${plan.dueCount} due cards · ${plan.planLine}',
              style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: UiSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: onStart,
                    child: const Text('Start catch-up'),
                  ),
                ),
                const SizedBox(width: UiSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onShowAll,
                    child: const Text('Show all'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CatchUpProgress extends StatelessWidget {
  final CatchUpView plan;

  const _CatchUpProgress({super.key, required this.plan});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: UiSpacing.sm),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        'Catch-up · ${plan.completedToday}/${plan.dailyCap} today · '
        '${plan.dueCount} due · about ${plan.estimatedDays} '
        '${plan.estimatedDays == 1 ? 'day' : 'days'} left',
        style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  final int due;
  final int neu;
  final int session;
  final bool offline;
  final int pendingSync;

  /// Reverts the last rating; null hides the undo button (nothing undoable).
  final VoidCallback? onUndo;

  /// Opens the flag-card sheet; null hides the flag button.
  final VoidCallback? onFlag;
  final VoidCallback? onOpenSettings;
  const _Header({
    required this.due,
    required this.neu,
    required this.session,
    required this.offline,
    required this.pendingSync,
    this.onUndo,
    this.onFlag,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'Study',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontSize: 24),
            ),
            if (offline || pendingSync > 0) ...[
              const SizedBox(width: UiSpacing.sm),
              RecallStatusPill(
                label: offline ? 'Offline' : '$pendingSync syncing',
                icon: offline ? Icons.cloud_off_outlined : Icons.sync,
              ),
            ],
            const Spacer(),
            if (onUndo != null)
              IconButton(
                tooltip: 'Undo last rating',
                icon: const Icon(
                  Icons.undo,
                  size: 20,
                  color: UiColors.textMuted,
                ),
                onPressed: onUndo,
              ),
            if (onFlag != null)
              IconButton(
                tooltip: 'Flag card',
                icon: const Icon(
                  Icons.flag_outlined,
                  size: 20,
                  color: UiColors.textMuted,
                ),
                onPressed: onFlag,
              ),
            if (onOpenSettings != null)
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(
                  Icons.settings_outlined,
                  size: 20,
                  color: UiColors.textMuted,
                ),
                onPressed: onOpenSettings,
              ),
          ],
        ),
        RecallMetricStrip(
          key: const Key('recall_queue_strip'),
          metrics: [
            RecallMetric(
              'Due',
              '$due',
              color: due > 0 ? UiColors.primary : null,
            ),
            RecallMetric(
              'New',
              '$neu',
              color: neu > 0 ? UiColors.chartBlue : null,
            ),
            RecallMetric('Done', '$session'),
          ],
        ),
      ],
    );
  }
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
      key: const Key('recall_study_card'),
      width: double.infinity,
      padding: const EdgeInsets.all(UiSpacing.lg),
      decoration: buildHeroPanelDecoration(),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Question',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: UiColors.primary,
                fontSize: 10,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: UiSpacing.md),
            CardFace(
              html: card.front,
              hasLatex: card.hasLatex,
              latexSvg: card.latexSvg,
              cacheKey: '${card.id}:front',
              style: style,
              selectable: false,
              // The deleted answers live in the front's {{cN::…}} markup, so the
              // front itself fills them in on flip (the back is the extra field
              // and is often just a summary). A no-op for non-cloze fronts.
              revealCloze: showBack,
            ),
            AnimatedSize(
              duration: RecallMotion.duration(context),
              curve: RecallMotion.curve,
              alignment: Alignment.topCenter,
              child: RecallMotionSwap(
                duration: RecallMotion.quick,
                child: showBack
                    ? Column(
                        key: ValueKey('study_answer_${card.id}'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: UiSpacing.lg,
                            ),
                            child: Divider(color: UiColors.border, height: 1),
                          ),
                          Text(
                            'Answer',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: UiColors.textMuted,
                                  fontSize: 10,
                                  letterSpacing: 1.1,
                                ),
                          ),
                          const SizedBox(height: UiSpacing.md),
                          CardFace(
                            html: card.back,
                            hasLatex: card.hasLatex,
                            latexSvg: card.latexSvg,
                            cacheKey: '${card.id}:back',
                            selectable: false,
                            textAlign: TextAlign.start,
                            style: style.copyWith(
                              color: UiColors.textSecondary,
                              fontWeight: FontWeight.w400,
                            ),
                            // The answer face reveals any cloze deletions it carries.
                            revealCloze: true,
                          ),
                        ],
                      )
                    : const SizedBox(key: ValueKey('study_answer_hidden')),
              ),
            ),
            const SizedBox(height: UiSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// The four flag reasons, in display order. The `reason` value maps to the
/// note_flags CHECK constraint; the `label` is the sheet's tap target.
const List<({String reason, String label})> _flagOptions = [
  (reason: 'wrong', label: 'Wrong'),
  (reason: 'confusing', label: 'Confusing'),
  (reason: 'too_long', label: 'Too long'),
  (reason: 'duplicate', label: 'Duplicate'),
];

/// A platform-appropriate sheet listing the flag reasons: Cupertino actions on
/// native iOS, the existing Material bottom sheet on web. Selecting one
/// enqueues the flag (durable, offline-safe), dismisses the sheet, and shows a
/// brief confirmation. The review flow is left completely untouched —
/// flagging never rates, skips, or advances the card. Cancel enqueues nothing.
void _showFlagSheet(
  BuildContext context,
  ReviewController controller, {
  required bool nativeIos,
}) {
  // Capture the messenger before any async gap — the sheet's own context is
  // gone by the time the confirmation fires.
  final messenger = ScaffoldMessenger.of(context);

  Future<void> selectReason(BuildContext sheetContext, String reason) async {
    // Capture the navigator pre-await — using sheetContext across the gap
    // trips use_build_context_synchronously.
    final navigator = Navigator.of(sheetContext);
    await controller.flag(reason);
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Card flagged'),
        ),
      );
  }

  if (nativeIos) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoTheme(
        data: CupertinoTheme.of(context).copyWith(
          brightness: Brightness.dark,
          primaryColor: Theme.of(context).colorScheme.primary,
          barBackgroundColor: UiColors.panel.withValues(alpha: 0.82),
        ),
        child: CupertinoActionSheet(
          title: const Text('Flag this card'),
          actions: [
            for (final option in _flagOptions)
              CupertinoActionSheetAction(
                onPressed: () => selectReason(sheetContext, option.reason),
                child: Text(option.label),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Cancel'),
          ),
        ),
      ),
    );
    return;
  }

  showModalBottomSheet<void>(
    context: context,
    backgroundColor: UiColors.panel,
    showDragHandle: true,
    builder: (sheetContext) {
      // Scrollable + compact so the sheet fits small screens/landscape and
      // never overflows; on a phone all options show without scrolling.
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  UiSpacing.lg,
                  0,
                  UiSpacing.lg,
                  UiSpacing.xs,
                ),
                child: Text(
                  'Flag this card',
                  style: TextStyle(
                    color: UiColors.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final option in _flagOptions)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(
                    Icons.flag_outlined,
                    size: 20,
                    color: UiColors.textSecondary,
                  ),
                  title: Text(
                    option.label,
                    style: const TextStyle(color: UiColors.textPrimary),
                  ),
                  onTap: () {
                    // The confirmation is a durability promise: a PWA can be
                    // backgrounded/killed the moment the user sees it, so the
                    // local enqueue must complete BEFORE we confirm. flag()
                    // awaits only the SharedPreferences write (fast); the
                    // network flush stays fire-and-forget inside it.
                    selectReason(sheetContext, option.reason);
                  },
                ),
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: const Text(
                  'Cancel',
                  style: TextStyle(color: UiColors.textMuted),
                ),
                onTap: () => Navigator.of(sheetContext).pop(),
              ),
              const SizedBox(height: UiSpacing.xs),
            ],
          ),
        ),
      );
    },
  );
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? action;
  final VoidCallback? onAction;
  final String? secondaryAction;
  final VoidCallback? onSecondaryAction;
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.onAction,
    this.secondaryAction,
    this.onSecondaryAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UiSpacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: RecallHeroPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 38, color: UiColors.primary),
                const SizedBox(height: UiSpacing.md),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: UiSpacing.sm),
                Text(
                  subtitle,
                  style: const TextStyle(color: UiColors.textMuted),
                ),
                if (action != null) ...[
                  const SizedBox(height: UiSpacing.lg),
                  FilledButton(onPressed: onAction, child: Text(action!)),
                ],
                if (secondaryAction != null) ...[
                  const SizedBox(height: UiSpacing.sm),
                  TextButton(
                    onPressed: onSecondaryAction,
                    child: Text(
                      secondaryAction!,
                      style: const TextStyle(color: UiColors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

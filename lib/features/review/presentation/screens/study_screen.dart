import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import '../../../../theme/ui_tokens.dart';
import '../../../../core/platform/recall_platform.dart';
import '../../../../core/widgets/recall_motion.dart';
import '../../../../core/widgets/recall_surfaces.dart';
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

  /// Opens settings from the secondary-actions menu.
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

  KeyEventResult _handleReviewKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      controller.flip();
    } else if (event.logicalKey == LogicalKeyboardKey.digit1) {
      unawaited(controller.rate(Rating.again));
    } else if (event.logicalKey == LogicalKeyboardKey.digit2) {
      unawaited(controller.rate(Rating.hard));
    } else if (event.logicalKey == LogicalKeyboardKey.digit3) {
      unawaited(controller.rate(Rating.good));
    } else if (event.logicalKey == LogicalKeyboardKey.digit4) {
      unawaited(controller.rate(Rating.easy));
    }
    // Keep the event available to the focused control. In particular, Space
    // must still activate a rating button reached through keyboard focus.
    return KeyEventResult.ignored;
  }

  Widget _completed(BuildContext context, Widget child) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Study',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'More options',
            icon: const Icon(Icons.more_horiz),
            onPressed: () => _showStudyOptions(
              context,
              controller,
              nativeIos: nativeIos ?? recallRunsAsNativeIos(),
              onOpenSettings: onOpenSettings,
            ),
          ),
        ],
      ),
      Expanded(child: child),
    ],
  );

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
          final reviewedLine = n > 0
              ? 'Reviewed $n ${n == 1 ? 'card' : 'cards'} this session.'
              : 'Nothing due right now.';
          if (s.catchUp.isActive && s.catchUp.dueCount > 0) {
            return _completed(
              context,
              RecallMotionSwap(
                child: _Message(
                  key: const ValueKey('study_catch_up_paused'),
                  icon: Icons.pause_circle_outline,
                  title: 'Session complete',
                  subtitle: n > 0 ? reviewedLine : 'You’re done for now.',
                  action: 'Reload',
                  onAction: controller.refresh,
                  secondaryAction: undoable ? 'Undo last rating' : null,
                  onSecondaryAction: undoable ? controller.undo : null,
                ),
              ),
            );
          }
          // "Keep going" pulls a bonus batch (cards due in the next 24h +
          // unseen new cards). It hides once a fetch came back empty, and
          // needs a connection — the just-made ratings must sync first.
          final canKeepGoing = !s.aheadExhausted && !s.offline;
          return _completed(
            context,
            RecallMotionSwap(
              child: ListView(
                key: const ValueKey('study_done'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(UiSpacing.lg),
                children: [
                  _Message(
                    icon: Icons.check_circle_outline,
                    title: 'All caught up',
                    subtitle: reviewedLine,
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
            ),
          );
        }

        final card = s.current!;
        final style = Theme.of(context).textTheme.titleLarge!.copyWith(
          color: UiColors.textPrimary,
          fontSize: 24,
          height: 1.45,
          fontWeight: FontWeight.w400,
        );

        String? selectedDeck;
        for (final deck in s.decks) {
          if (deck.deckId == s.deckFilter) selectedDeck = deck.name;
        }
        final header = _Header(
          title: selectedDeck?.replaceAll('::', ' › ') ?? 'Study',
          due: s.dueRemaining,
          neu: s.newRemaining,
          session: s.reviewedThisSession,
          offline: s.offline,
          pendingSync: s.pendingSync,
          onUndo: undoable ? controller.undo : null,
          onMore: () => _showStudyOptions(
            context,
            controller,
            nativeIos: nativeIos ?? recallRunsAsNativeIos(),
            onOpenSettings: onOpenSettings,
          ),
          onSession: () => _showSessionOptions(
            context,
            controller,
            nativeIos: nativeIos ?? recallRunsAsNativeIos(),
          ),
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

        final body = RecallMotionSwap(
          child: accessibleScroll
              ? ListView(
                  key: ValueKey('study_card_${card.id}'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
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
                    header,
                    const SizedBox(height: UiSpacing.sm),
                    Expanded(child: cardPanel),
                    const SizedBox(height: UiSpacing.md),
                    actions,
                    const SizedBox(height: UiSpacing.sm),
                  ],
                ),
        );
        return Focus(
          autofocus: true,
          onKeyEvent: _handleReviewKey,
          child: body,
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final int due;
  final int neu;
  final int session;
  final bool offline;
  final int pendingSync;
  final VoidCallback? onUndo;
  final VoidCallback onMore;
  final VoidCallback onSession;
  const _Header({
    required this.title,
    required this.due,
    required this.neu,
    required this.session,
    required this.offline,
    required this.pendingSync,
    required this.onMore,
    required this.onSession,
    this.onUndo,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onUndo != null)
            IconButton(
              tooltip: 'Undo last rating',
              icon: const Icon(Icons.undo, size: 20),
              onPressed: onUndo,
            ),
          IconButton(
            tooltip: 'More options',
            icon: const Icon(Icons.more_horiz, size: 22),
            onPressed: onMore,
          ),
        ],
      ),
      Row(
        key: const Key('recall_queue_strip'),
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: 'Session options',
                child: TextButton.icon(
                  onPressed: onSession,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 15),
                  iconAlignment: IconAlignment.end,
                  label: Text(
                    '$due due · $neu new',
                    style: const TextStyle(fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: UiColors.textSecondary,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 2,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$session done',
            style: const TextStyle(fontSize: 13, color: UiColors.textMuted),
          ),
        ],
      ),
      if (offline || pendingSync > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(
              offline
                  ? (pendingSync > 0
                        ? 'Offline · $pendingSync waiting to sync'
                        : 'Offline')
                  : '$pendingSync syncing',
              style: const TextStyle(
                color: UiColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ),
    ],
  );
}

Future<String?> _studySheet(
  BuildContext context, {
  required bool nativeIos,
  required String title,
  String? message,
  required List<({String value, String label, IconData icon})> actions,
}) {
  if (nativeIos) {
    return showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoTheme(
        data: CupertinoTheme.of(
          context,
        ).copyWith(brightness: Brightness.dark, primaryColor: UiColors.primary),
        child: CupertinoActionSheet(
          title: Text(title),
          message: message == null ? null : Text(message),
          actions: [
            for (final action in actions)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(sheetContext, action.value),
                child: Text(action.label),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext),
            child: const Text('Cancel'),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 8),
                    child: Text(
                      message,
                      style: const TextStyle(color: UiColors.textSecondary),
                    ),
                  ),
                const SizedBox(height: 8),
                for (final action in actions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      action.icon,
                      size: 20,
                      color: UiColors.textMuted,
                    ),
                    title: Text(action.label),
                    onTap: () => Navigator.pop(sheetContext, action.value),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _showStudyOptions(
  BuildContext context,
  ReviewController controller, {
  required bool nativeIos,
  VoidCallback? onOpenSettings,
}) async {
  final choice = await _studySheet(
    context,
    nativeIos: nativeIos,
    title: 'Options',
    actions: [
      (value: 'session', label: 'Session options', icon: Icons.tune),
      if (controller.state.current != null)
        (value: 'flag', label: 'Flag card', icon: Icons.flag_outlined),
      if (onOpenSettings != null)
        (value: 'settings', label: 'Settings', icon: Icons.settings_outlined),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'session':
      await _showSessionOptions(context, controller, nativeIos: nativeIos);
    case 'flag':
      _showFlagSheet(context, controller, nativeIos: nativeIos);
    case 'settings':
      onOpenSettings?.call();
  }
}

Future<void> _showSessionOptions(
  BuildContext context,
  ReviewController controller, {
  required bool nativeIos,
}) async {
  final state = controller.state;
  final plan = state.catchUp;
  final choice = await _studySheet(
    context,
    nativeIos: nativeIos,
    title: 'Your session',
    message: plan.isActive
        ? 'Catch-up · ${plan.remainingToday} cards left today.'
        : '${state.dueRemaining} due cards · ${state.newRemaining} new',
    actions: [
      if (plan.isEligible && !plan.isActive)
        (
          value: 'catchup',
          label: 'Start catch-up',
          icon: Icons.play_arrow_outlined,
        ),
      if (plan.isActive || plan.isEligible)
        (
          value: 'all',
          label: 'Review all due cards',
          icon: Icons.all_inclusive,
        ),
    ],
  );
  if (!context.mounted) return;
  if (choice == 'catchup') await controller.startCatchUp();
  if (choice == 'all') await controller.showAll();
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
            CardFace(
              html: card.front,
              textAlign: TextAlign.start,
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
                          CardFace(
                            html: card.back,
                            hasLatex: card.hasLatex,
                            latexSvg: card.latexSvg,
                            cacheKey: '${card.id}:back',
                            selectable: false,
                            textAlign: TextAlign.start,
                            style: style.copyWith(
                              color: UiColors.textSecondary,
                              fontSize: 18,
                              height: 1.6,
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

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
import '../../data/local_review_preferences.dart';
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

  KeyEventResult _handleReviewKey(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    // Consume held review keys without repeating an action or allowing Space
    // to scroll the study surface. Focused controls retain their own activation.
    if (event is KeyRepeatEvent &&
        node.hasPrimaryFocus &&
        const [
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
        ].contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      // A focused button owns Space for activation. Only the study surface
      // consumes the review shortcut, preventing the default scroll action.
      if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
      if (controller.state.showBack) {
        unawaited(_absorbRefusedSave(controller.rate(Rating.good)));
      } else {
        controller.flip();
      }
    } else if (event.logicalKey == LogicalKeyboardKey.digit1) {
      unawaited(_absorbRefusedSave(controller.rate(Rating.again)));
    } else if (event.logicalKey == LogicalKeyboardKey.digit2) {
      unawaited(_absorbRefusedSave(controller.rate(Rating.hard)));
    } else if (event.logicalKey == LogicalKeyboardKey.digit3) {
      unawaited(_absorbRefusedSave(controller.rate(Rating.good)));
    } else if (event.logicalKey == LogicalKeyboardKey.digit4) {
      unawaited(_absorbRefusedSave(controller.rate(Rating.easy)));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _completed(BuildContext context, Widget child) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Study',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: 'More options',
            icon: const Icon(Icons.more_horiz, size: 20),
            onPressed: () => _showStudyOptions(
              context,
              controller,
              nativeIos: nativeIos ?? recallRunsAsNativeIos(),
              onOpenSettings: onOpenSettings,
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          label:
              '${controller.state.reviewedToday} ${controller.state.reviewedToday == 1 ? 'card' : 'cards'} reviewed today',
          excludeSemantics: true,
          child: Text(
            '${controller.state.reviewedToday} done',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
      if (controller.flagNotice != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            liveRegion: true,
            child: Text(
              controller.flagNotice!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: UiColors.textSecondary),
            ),
          ),
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
        final undoLabel = s.undoRestoresHiddenCard
            ? 'Undo hide'
            : 'Undo last rating';

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
                  announceSubtitle: true,
                  action: 'Reload',
                  onAction: controller.refresh,
                  secondaryAction: undoable ? undoLabel : null,
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
                    announceSubtitle: true,
                    action: canKeepGoing ? 'Keep going' : 'Reload',
                    onAction: canKeepGoing
                        ? controller.keepGoing
                        : controller.refresh,
                    // A mis-tap on the session's last card lands here — keep it
                    // recoverable (undo survives until the queue is reloaded).
                    secondaryAction: undoable
                        ? undoLabel
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
        final style = Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: UiColors.textPrimary,
          height: 1.45,
          fontWeight: FontWeight.w400,
        );

        String? selectedDeck;
        String? cardDeck;
        for (final deck in s.decks) {
          if (deck.deckId == s.deckFilter) selectedDeck = deck.name;
          if (deck.deckId == card.deckId) cardDeck = deck.name;
        }
        final header = _Header(
          title: selectedDeck?.replaceAll('::', ' › ') ?? 'Study',
          due: s.dueRemaining,
          neu: s.newRemaining,
          session: s.reviewedThisSession,
          today: s.reviewedToday,
          offline: s.offline,
          serverError: s.serverError,
          pendingSync: s.pendingSync,
          syncErrors: s.syncErrors,
          onUndo: undoable ? controller.undo : null,
          notice: controller.flagNotice,
          liked: controller.currentLiked,
          onLike: controller.rateInFlight || controller.likeInFlight
              ? null
              : () => unawaited(_absorbRefusedSave(controller.toggleLike())),
          onDislike: controller.rateInFlight
              ? null
              : () => unawaited(
                  _absorbRefusedSave(controller.hideCurrent('dislike')),
                ),
          onDelete: controller.rateInFlight
              ? null
              : () => unawaited(
                  _absorbRefusedSave(controller.hideCurrent('delete')),
                ),
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
          deckName: cardDeck?.replaceAll('::', ' › ') ?? 'Deck',
          showBack: s.showBack,
          style: style,
        );
        // Both controls participate in layout, so the real rating buttons
        // reserve their final height at every width and text scale. Inactive
        // controls are excluded from paint, semantics, pointer and focus input.
        final actions = IndexedStack(
          index: s.showBack ? 1 : 0,
          alignment: Alignment.center,
          children: [
            ExcludeFocus(
              excluding: s.showBack,
              child: SizedBox(
                key: const ValueKey('study_show_answer'),
                width: double.infinity,
                child: FilledButton(
                  onPressed: controller.flip,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
                  ),
                  child: const Text('Show answer'),
                ),
              ),
            ),
            ExcludeFocus(
              excluding: !s.showBack,
              child: RatingBar(
                key: const ValueKey('study_rating_bar'),
                onRate: (rating) =>
                    unawaited(_absorbRefusedSave(controller.rate(rating))),
                enabled: !controller.rateInFlight,
              ),
            ),
          ],
        );
        final body = LayoutBuilder(
          builder: (context, constraints) {
            // Short landscape windows need the same scrollable study surface as
            // large type; otherwise the fixed controls can squeeze the card away.
            final accessibleScroll =
                MediaQuery.textScalerOf(context).scale(1) > 1.3 ||
                constraints.maxHeight < 420;
            // A rating already waits for its durable local save. Present the
            // next question in that first frame instead of fading the entire
            // study surface out/in on every card id change.
            return accessibleScroll
                ? SingleChildScrollView(
                    key: ValueKey('study_card_${card.id}'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: UiSpacing.sm),
                        // Preserve the original reading viewport as the footer
                        // grows with accessible type.
                        SizedBox(
                          height:
                              260 +
                              MediaQuery.textScalerOf(context).scale(12) * 1.5 +
                              UiSpacing.sm * 2 +
                              1,
                          child: cardPanel,
                        ),
                        const SizedBox(height: UiSpacing.md),
                        actions,
                        const SizedBox(height: UiSpacing.sm),
                      ],
                    ),
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
                  );
          },
        );
        return Focus(
          autofocus: true,
          onKeyEvent: _handleReviewKey,
          child: Builder(
            builder: (focusContext) => Listener(
              behavior: HitTestBehavior.opaque,
              // Reading owns keyboard focus while it is being used. A click
              // back into Study restores its shortcuts without revealing.
              // Web text fields unfocus on pointer-down outside their input.
              // Restore Study afterward so that action cannot steal it back.
              onPointerUp: (_) => Focus.of(focusContext).requestFocus(),
              child: body,
            ),
          ),
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
  final int today;
  final bool offline;

  /// With [offline]: the server answered with an error, so the saved queue is
  /// labelled as such rather than as offline.
  final bool serverError;
  final int pendingSync;
  final int syncErrors;
  final VoidCallback? onUndo;
  final VoidCallback? onDislike;
  final VoidCallback? onLike;
  final bool liked;
  final VoidCallback? onDelete;
  final String? notice;
  final VoidCallback onMore;
  final VoidCallback onSession;
  const _Header({
    required this.title,
    required this.due,
    required this.neu,
    required this.session,
    required this.today,
    required this.offline,
    required this.pendingSync,
    required this.onMore,
    this.syncErrors = 0,
    this.serverError = false,
    required this.onSession,
    this.onUndo,
    this.onDislike,
    this.onLike,
    this.liked = false,
    this.onDelete,
    this.notice,
  });

  /// Permanently refused reviews stay queued, so they are split out instead of
  /// claiming to sync forever.
  String get _onlineSyncLine {
    final syncing = pendingSync - syncErrors;
    return [
      if (syncing > 0) '$syncing syncing',
      if (syncErrors > 0) '$syncErrors couldn’t sync',
    ].join(' · ');
  }

  String get offlineLabel => serverError ? 'Server error' : 'Offline';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final stackActions =
              constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          final heading = Text(
            key: const Key('recall_study_title'),
            title,
            maxLines: stackActions ? null : 1,
            overflow: stackActions ? null : TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reserve Undo before the four main actions so they stay evenly
              // spaced and never shift when a hide or rating becomes undoable.
              Visibility(
                visible: onUndo != null,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(Icons.undo, size: 20),
                  onPressed: onUndo,
                ),
              ),
              IconButton(
                key: const Key('recall_flag_like'),
                tooltip: 'Like it · keep this style',
                isSelected: liked,
                icon: const Icon(Icons.thumb_up_outlined, size: 20),
                selectedIcon: const Icon(Icons.thumb_up, size: 20),
                onPressed: onLike,
              ),
              IconButton(
                key: const Key('recall_flag_dislike'),
                tooltip: 'Don’t like it · hide until Sunday review',
                icon: const Icon(Icons.thumb_down_outlined, size: 20),
                onPressed: onDislike,
              ),
              IconButton(
                key: const Key('recall_flag_delete'),
                tooltip: 'Flag for deletion',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onDelete,
              ),
              IconButton(
                tooltip: 'More options',
                icon: const Icon(Icons.more_horiz, size: 20),
                onPressed: onMore,
              ),
            ],
          );
          if (stackActions) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              actions,
            ],
          );
        },
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
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  iconAlignment: IconAlignment.end,
                  label: Text(
                    '$due due · $neu new',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: UiColors.textSecondary,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: UiColors.textSecondary,
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 0,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // The flag confirmation takes this slot for a moment instead of a
          // popup, so nothing ever covers the card or the rating buttons.
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: AnimatedSwitcher(
                duration: RecallMotion.duration(context, RecallMotion.quick),
                child: Semantics(
                  key: ValueKey(notice ?? 'session'),
                  // Preserve session feedback for ratings/Undo; expose the
                  // durable daily total as its own accessible metric below.
                  liveRegion: true,
                  label:
                      notice ??
                      '$session ${session == 1 ? 'card' : 'cards'} reviewed this session',
                  container: true,
                  explicitChildNodes: true,
                  child: Semantics(
                    label: notice == null
                        ? '$today ${today == 1 ? 'card' : 'cards'} reviewed today'
                        : '',
                    excludeSemantics: true,
                    child: Text(
                      notice ?? '$today done',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: notice == null
                            ? UiColors.textMuted
                            : UiColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      // Blank caption lines reserve the slot with the same font metrics as
      // feedback. Large type gets two lines; unusually long feedback remains
      // scrollable instead of truncating or displacing the card.
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Stack(
          children: [
            Text(
              MediaQuery.textScalerOf(context).scale(1) > 1.3 ? '\n' : '',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: UiColors.textSecondary),
            ),
            Positioned.fill(
              child: SingleChildScrollView(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    offline
                        ? (pendingSync > 0
                              ? '$offlineLabel · $pendingSync waiting to sync'
                              : offlineLabel)
                        : (pendingSync > 0 ? _onlineSyncLine : ''),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: UiColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
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
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: RecallMotion.slow,
            reverseDuration: RecallMotion.base,
          ),
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
  final String deckName;
  final bool showBack;
  final TextStyle style;
  const _CardPanel({
    required this.card,
    required this.deckName,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
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
                                  child: Divider(
                                    color: UiColors.border,
                                    height: 1,
                                  ),
                                ),
                                CardFace(
                                  html: card.back,
                                  hasLatex: card.hasLatex,
                                  latexSvg: card.latexSvg,
                                  cacheKey: '${card.id}:back',
                                  selectable: false,
                                  textAlign: TextAlign.start,
                                  style: Theme.of(context).textTheme.titleLarge!
                                      .copyWith(
                                        color: UiColors.textSecondary,
                                        height: 1.6,
                                        fontWeight: FontWeight.w400,
                                      ),
                                  // The answer face reveals any cloze deletions it carries.
                                  revealCloze: true,
                                ),
                              ],
                            )
                          : const SizedBox(
                              key: ValueKey('study_answer_hidden'),
                            ),
                    ),
                  ),
                  const SizedBox(height: UiSpacing.sm),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: UiSpacing.sm),
            child: Divider(color: UiColors.borderSubtle, height: 1),
          ),
          DefaultTextStyle(
            style: Theme.of(
              context,
            ).textTheme.bodySmall!.copyWith(color: UiColors.textMuted),
            child: Row(
              key: const Key('recall_study_card_footer'),
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(deckName, maxLines: 1),
                  ),
                ),
                const SizedBox(width: UiSpacing.md),
                Text(card.isNew ? 'New' : 'Review'),
              ],
            ),
          ),
        ],
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

/// The controller reports an unsaved action through the header notice and
/// then rethrows it for its callers. A gesture only has to absorb it, so the
/// card stays answerable and no unhandled error escapes.
Future<void> _absorbRefusedSave(Future<void> action) async {
  try {
    await action;
  } on LocalOutboxWriteException {
    // Shown as the study header notice; nothing was saved.
  } on LocalPreferenceWriteNotCommitted {
    // Shown as the study header notice; nothing was saved.
  } on StudyActionNotSavedException {
    // Shown as the study header notice; native truth holds nothing.
  } on StudyActionUnconfirmedException {
    // Shown as the study header notice; a redo cannot save it twice.
  }
}

/// A platform-appropriate sheet listing the flag reasons: Cupertino actions on
/// native iOS, the existing Material bottom sheet on web. Selecting one
/// enqueues the flag (durable, offline-safe), dismisses the sheet, and shows a
/// brief inline confirmation in the header. The review flow is left completely untouched —
/// flagging never rates, skips, or advances the card. Cancel enqueues nothing.
void _showFlagSheet(
  BuildContext context,
  ReviewController controller, {
  required bool nativeIos,
}) {
  var submitting = false;
  Future<void> selectReason(BuildContext sheetContext, String reason) async {
    if (submitting) return;
    submitting = true;
    // Capture the navigator pre-await — using sheetContext across the gap
    // trips use_build_context_synchronously. The confirmation is the header's
    // inline notice, shown once the flag is durably queued.
    final navigator = Navigator.of(sheetContext);
    final route = ModalRoute.of(sheetContext);
    try {
      await _absorbRefusedSave(controller.flag(reason));
      // Cancel, Back or a swipe may already have dismissed this sheet while
      // storage was busy. Never pop the study route underneath it.
      if (route?.isCurrent == true) navigator.pop();
    } finally {
      submitting = false;
    }
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
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: RecallMotion.slow,
            reverseDuration: RecallMotion.base,
          ),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UiSpacing.lg,
                  0,
                  UiSpacing.lg,
                  UiSpacing.xs,
                ),
                child: Text(
                  'Flag this card',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: UiColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final option in _flagOptions)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.standard,
                  minTileHeight: 48,
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
                visualDensity: VisualDensity.standard,
                minTileHeight: 48,
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
  final bool announceSubtitle;
  final String? action;
  final VoidCallback? onAction;
  final String? secondaryAction;
  final VoidCallback? onSecondaryAction;
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.announceSubtitle = false,
    this.action,
    this.onAction,
    this.secondaryAction,
    this.onSecondaryAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(UiSpacing.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: RecallHeroPanel(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 38, color: UiColors.textSecondary),
                  const SizedBox(height: UiSpacing.md),
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: UiSpacing.sm),
                  Semantics(
                    liveRegion: announceSubtitle,
                    child: Text(
                      subtitle,
                      style: const TextStyle(color: UiColors.textMuted),
                    ),
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
      ),
    );
  }
}

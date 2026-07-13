import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show scopedPanelColor;

import '../../../../theme/ui_tokens.dart';
import '../../../../core/platform/recall_platform.dart';
import '../../application/review_controller.dart';
import '../../data/models.dart';
import '../widgets/card_face.dart';
import '../widgets/rating_bar.dart';

class StudyScreen extends StatelessWidget {
  final ReviewController controller;

  /// Opens the settings screen from the header gear. Null hides the gear.
  final VoidCallback? onOpenSettings;
  final bool? nativeIos;

  const StudyScreen({
    super.key,
    required this.controller,
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
            // A mis-tap on the session's last card lands here — keep it
            // recoverable (undo survives until the queue is reloaded).
            secondaryAction: undoable ? 'Undo last rating' : null,
            onSecondaryAction: undoable ? controller.undo : null,
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
              onUndo: undoable ? controller.undo : null,
              // Flagging is independent of the review flow and of undo — it
              // only reports the current card, so it's live whenever a card
              // is on screen (the header only renders with a current card).
              onFlag: () => _showFlagSheet(
                context,
                controller,
                nativeIos: nativeIos ?? recallRunsAsNativeIos(),
              ),
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
        if (onUndo != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Undo last rating',
            icon: const Icon(Icons.undo, size: 20, color: UiColors.textMuted),
            onPressed: onUndo,
          ),
        if (onFlag != null)
          IconButton(
            visualDensity: VisualDensity.compact,
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
              // The deleted answers live in the front's {{cN::…}} markup, so the
              // front itself fills them in on flip (the back is the extra field
              // and is often just a summary). A no-op for non-cloze fronts.
              revealCloze: showBack,
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
                // The answer face reveals any cloze deletions it carries.
                revealCloze: true,
              ),
            ],
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
    );
  }
}

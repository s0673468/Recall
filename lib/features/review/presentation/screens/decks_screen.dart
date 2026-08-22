import 'package:flutter/material.dart';

import '../../../../core/widgets/recall_motion.dart';
import '../../../../core/widgets/recall_page_header.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../data/models.dart';
import '../../data/recall_api.dart';

/// Open the automatic stream or one explicit deck, with per-deck due/new
/// counts. Tapping starts that session and jumps to the Study tab.
class DecksScreen extends StatefulWidget {
  final ReviewController controller;
  final RecallApi api;
  final void Function(int? deckId) onStudyDeck;

  const DecksScreen({
    super.key,
    required this.controller,
    required this.api,
    required this.onStudyDeck,
  });

  @override
  State<DecksScreen> createState() => DecksScreenState();
}

class DecksScreenState extends State<DecksScreen> {
  late Future<Map<int, ({int due, int neu})>> _counts;

  @override
  void initState() {
    super.initState();
    _counts = widget.api.fetchDeckCounts();
  }

  Future<void> reload() async {
    setState(() {
      _counts = widget.api.fetchDeckCounts();
    });
    await _counts;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final decks = widget.controller.state.decks;
        final automaticDeckIds = automaticReviewDeckIds(decks);
        final coreDecks = decks
            .where((deck) => automaticDeckIds.contains(deck.deckId))
            .toList();
        final optionalDecks = decks
            .where((deck) => !automaticDeckIds.contains(deck.deckId))
            .toList();
        return RefreshIndicator(
          onRefresh: reload,
          child: FutureBuilder<Map<int, ({int due, int neu})>>(
            future: _counts,
            builder: (context, snap) {
              final counts = snap.data;
              final totalDue = counts?.entries.fold(
                0,
                (total, entry) =>
                    total +
                    (automaticDeckIds.contains(entry.key)
                        ? entry.value.due
                        : 0),
              );
              final totalNew = counts?.entries.fold(
                0,
                (total, entry) =>
                    total +
                    (automaticDeckIds.contains(entry.key)
                        ? entry.value.neu
                        : 0),
              );
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  UiSpacing.md,
                  UiSpacing.md,
                  UiSpacing.md,
                  UiSpacing.xl,
                ),
                children: [
                  const RecallPageHeader(
                    eyebrow: 'Library',
                    title: 'Decks',
                    subtitle:
                        'Core learning flows into one review. Optional '
                        'curricula stay available when you choose them.',
                  ),
                  const SizedBox(height: UiSpacing.lg),
                  RecallMotionSwap(
                    child: snap.hasError
                        ? _CountError(onRetry: _retry)
                        : snap.connectionState == ConnectionState.done
                        ? const SizedBox(
                            key: ValueKey('deck_counts_ready'),
                            height: UiSpacing.xs,
                          )
                        : const Padding(
                            key: ValueKey('deck_counts_loading'),
                            padding: EdgeInsets.symmetric(
                              horizontal: UiSpacing.sm,
                            ),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                  ),
                  _automaticHero(
                    due: totalDue,
                    neu: totalNew,
                    onTap: () => widget.onStudyDeck(null),
                  ),
                  if (coreDecks.isNotEmpty) ...[
                    const SizedBox(height: UiSpacing.xl),
                    const RecallSectionLabel(
                      title: 'Core decks',
                      subtitle: 'Included in automatic review.',
                    ),
                    const SizedBox(height: UiSpacing.sm),
                    _deckGroup(coreDecks, counts, manualOnly: false),
                  ],
                  if (optionalDecks.isNotEmpty) ...[
                    const SizedBox(height: UiSpacing.xl),
                    const RecallSectionLabel(
                      title: 'Optional curricula',
                      subtitle:
                          'Open one explicitly when you want to study it.',
                    ),
                    const SizedBox(height: UiSpacing.sm),
                    _deckGroup(optionalDecks, counts, manualOnly: true),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _automaticHero({
    required int? due,
    required int? neu,
    required VoidCallback onTap,
  }) {
    final dueLabel = due == null ? '—' : '$due';
    final newLabel = neu == null ? '—' : '$neu';
    return KeyedSubtree(
      key: const Key('recall_deck_row_Automatic review'),
      child: RecallHeroPanel(
        key: const Key('recall_deck_hero'),
        onTap: onTap,
        semanticsLabel: 'Start automatic review',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: UiColors.primaryMuted,
                borderRadius: BorderRadius.circular(UiRadius.lg),
              ),
              child: const Icon(
                Icons.all_inclusive,
                color: UiColors.primary,
                size: 25,
              ),
            ),
            const SizedBox(width: UiSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Automatic review',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: UiSpacing.xs),
                  Text(
                    'Your core topics, mixed into the next useful session.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: UiColors.textMuted),
                  ),
                  const SizedBox(height: UiSpacing.md),
                  Wrap(
                    spacing: UiSpacing.sm,
                    runSpacing: UiSpacing.xs,
                    children: [
                      RecallStatusPill(
                        label: '$dueLabel due',
                        color: UiColors.primary,
                      ),
                      RecallStatusPill(
                        label: '$newLabel new',
                        color: UiColors.chartBlue,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: UiSpacing.sm),
            const Icon(
              Icons.arrow_forward_rounded,
              color: UiColors.primary,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _deckGroup(
    List<DeckRow> decks,
    Map<int, ({int due, int neu})>? counts, {
    required bool manualOnly,
  }) => RecallListGroup(
    children: [
      for (final deck in decks)
        _tile(
          label: deck.name.replaceAll('::', '  ›  '),
          icon: manualOnly ? Icons.touch_app_outlined : Icons.folder_outlined,
          due: counts?[deck.deckId]?.due,
          neu: counts?[deck.deckId]?.neu,
          manualOnly: manualOnly,
          onTap: () => widget.onStudyDeck(deck.deckId),
        ),
    ],
  );

  Widget _tile({
    required String label,
    required IconData icon,
    required int? due,
    required int? neu,
    bool manualOnly = false,
    required VoidCallback onTap,
  }) {
    return KeyedSubtree(
      key: ValueKey('recall_deck_row_$label'),
      child: RecallListRow(
        icon: icon,
        iconColor: manualOnly ? UiColors.chartBlue : UiColors.textSecondary,
        title: label,
        subtitle: manualOnly ? 'Open manually' : 'Part of automatic review',
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (due != null && due > 0) _count('$due due', UiColors.primary),
            if (neu != null && neu > 0) _count('$neu new', UiColors.chartBlue),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _count(String n, Color color) => Text(
    n,
    style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
  );

  void _retry() {
    setState(() {
      _counts = widget.api.fetchDeckCounts();
    });
  }
}

class _CountError extends StatelessWidget {
  final VoidCallback onRetry;

  const _CountError({required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('deck_counts_error'),
    padding: const EdgeInsets.fromLTRB(
      UiSpacing.sm,
      UiSpacing.xs,
      UiSpacing.sm,
      UiSpacing.sm,
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Could not load deck counts.',
            style: TextStyle(color: UiColors.textMuted, fontSize: 12),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

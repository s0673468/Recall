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
  final _searchController = TextEditingController();
  String _query = '';
  bool _optionalExpanded = false;

  @override
  void initState() {
    super.initState();
    _counts = widget.api.fetchDeckCounts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
        final query = _query.trim().toLowerCase().replaceAll('::', ' ');
        final matches = decks.where(
          (deck) =>
              deck.name.replaceAll('::', ' ').toLowerCase().contains(query),
        );
        final coreDecks = matches
            .where((deck) => automaticDeckIds.contains(deck.deckId))
            .toList();
        final optionalDecks = matches
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
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(
                  UiSpacing.md,
                  UiSpacing.md,
                  UiSpacing.md,
                  UiSpacing.xl,
                ),
                children: [
                  const RecallPageHeader(title: 'Decks'),
                  const SizedBox(height: UiSpacing.lg),
                  TextField(
                    key: const Key('recall_deck_search'),
                    controller: _searchController,
                    autocorrect: false,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Find a deck',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                              icon: const Icon(Icons.close, size: 20),
                            ),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: UiSpacing.lg),
                  RecallMotionSwap(
                    child: snap.hasError
                        ? _CountError(onRetry: _retry)
                        : snap.connectionState == ConnectionState.done
                        ? const SizedBox.shrink(
                            key: ValueKey('deck_counts_ready'),
                          )
                        : const Padding(
                            key: ValueKey('deck_counts_loading'),
                            padding: EdgeInsets.only(bottom: UiSpacing.sm),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                  ),
                  if (query.isEmpty)
                    _automaticHero(
                      due: totalDue,
                      neu: totalNew,
                      onTap: () => widget.onStudyDeck(null),
                    ),
                  if (coreDecks.isNotEmpty) ...[
                    const SizedBox(height: UiSpacing.lg),
                    const Text(
                      'Included in automatic review',
                      style: TextStyle(fontSize: 12, color: UiColors.textMuted),
                    ),
                    const SizedBox(height: UiSpacing.sm),
                    _deckGroup(coreDecks, counts),
                  ],
                  if (optionalDecks.isNotEmpty) ...[
                    const SizedBox(height: UiSpacing.lg),
                    ExpansionTile(
                      key: ValueKey(
                        'recall_optional_decks_${query.isNotEmpty}',
                      ),
                      initiallyExpanded: query.isNotEmpty || _optionalExpanded,
                      onExpansionChanged: (expanded) {
                        if (query.isEmpty) _optionalExpanded = expanded;
                      },
                      tilePadding: const EdgeInsets.symmetric(
                        horizontal: UiSpacing.xs,
                      ),
                      childrenPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          const Expanded(child: Text('Optional curricula')),
                          const SizedBox(width: UiSpacing.sm),
                          Text(
                            '${optionalDecks.length}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      children: [_deckGroup(optionalDecks, counts)],
                    ),
                  ],
                  if (query.isNotEmpty && matches.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: UiSpacing.lg),
                      child: Text(
                        'No matching decks.',
                        style: TextStyle(color: UiColors.textMuted),
                      ),
                    ),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Automatic review',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: UiSpacing.sm),
            Text(
              'Your core decks · $dueLabel due · $newLabel new',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: UiColors.textMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: UiSpacing.lg),
            FilledButton(onPressed: onTap, child: const Text('Start review')),
          ],
        ),
      ),
    );
  }

  Widget _deckGroup(
    List<DeckRow> decks,
    Map<int, ({int due, int neu})>? counts,
  ) => RecallListGroup(
    children: [
      for (final deck in decks)
        _tile(
          label: deck.name.replaceAll('::', '  ›  '),
          due: counts?[deck.deckId]?.due,
          neu: counts?[deck.deckId]?.neu,
          onTap: () => widget.onStudyDeck(deck.deckId),
        ),
    ],
  );

  Widget _tile({
    required String label,
    required int? due,
    required int? neu,
    required VoidCallback onTap,
  }) {
    final labels = [
      if (due != null) '$due due',
      if (neu != null && neu > 0) '$neu new',
    ];
    return KeyedSubtree(
      key: ValueKey('recall_deck_row_$label'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackCounts =
              constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(14) > 18;
          return RecallListRow(
            title: label,
            subtitle: stackCounts && labels.isNotEmpty
                ? labels.join(' · ')
                : null,
            trailing: stackCounts || labels.isEmpty
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final label in labels)
                        Text(
                          label,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: UiColors.textMuted),
                        ),
                    ],
                  ),
            onTap: onTap,
          );
        },
      ),
    );
  }

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
    padding: const EdgeInsets.only(bottom: UiSpacing.sm),
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

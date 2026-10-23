import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/widgets/listenable_selector.dart';
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
  late List<DeckRow> _countDecks;
  late int _pendingSync;
  final _searchController = TextEditingController();
  String _query = '';
  bool _optionalExpanded = false;

  @override
  void initState() {
    super.initState();
    _counts = widget.api.fetchDeckCounts();
    _countDecks = widget.controller.state.decks;
    _pendingSync = widget.controller.state.pendingSync;
    widget.controller.addListener(_onDecksChanged);
  }

  @override
  void didUpdateWidget(covariant DecksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onDecksChanged);
      widget.controller.addListener(_onDecksChanged);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.api != widget.api ||
        !identical(_countDecks, widget.controller.state.decks)) {
      _onDecksChanged(force: true);
    }
  }

  void _onDecksChanged({bool force = false}) {
    final state = widget.controller.state;
    final decks = state.decks;
    final drained = state.pendingSync < _pendingSync;
    _pendingSync = state.pendingSync;
    if (!force && !drained && identical(_countDecks, decks)) return;
    _countDecks = decks;
    // Loads publish a refreshed deck list; outbox drains can change counts
    // without replacing it. Refresh both while unrelated ticks stay free.
    // FutureBuilder presents failures, so this notification listener must also
    // consume reload's error rather than leaking an unhandled async failure.
    unawaited(reload().catchError((Object _) {}));
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onDecksChanged);
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
    // The outer selector rebuilds only for deck-list replacements. Counts
    // refresh independently after loads and outbox drains.
    return ListenableSelector<List<DeckRow>>(
      listenable: widget.controller,
      selector: () => widget.controller.state.decks,
      equals: identical,
      builder: (context, decks) {
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
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  _sliverBox(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: UiSpacing.md),
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
                                      _setQuery('');
                                    },
                                    icon: const Icon(Icons.close, size: 20),
                                  ),
                          ),
                          onChanged: _setQuery,
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
                      ],
                    ),
                  ),
                  if (coreDecks.isNotEmpty) ...[
                    _sliverBox(
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: UiSpacing.lg),
                          Text(
                            'Included in automatic review',
                            style: TextStyle(
                              fontSize: 12,
                              color: UiColors.textMuted,
                            ),
                          ),
                          SizedBox(height: UiSpacing.sm),
                        ],
                      ),
                    ),
                    _deckGroup(coreDecks, counts),
                  ],
                  if (optionalDecks.isNotEmpty)
                    _OptionalDecks(
                      key: ValueKey(query.isNotEmpty),
                      searching: query.isNotEmpty,
                      initiallyExpanded: query.isNotEmpty || _optionalExpanded,
                      count: optionalDecks.length,
                      onExpansionChanged: (expanded) {
                        if (query.isEmpty) _optionalExpanded = expanded;
                      },
                      sliver: _deckGroup(optionalDecks, counts),
                    ),
                  if (query.isNotEmpty && matches.isEmpty)
                    _sliverBox(
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: UiSpacing.lg),
                        child: Text(
                          'No matching decks.',
                          style: TextStyle(color: UiColors.textMuted),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: UiSpacing.xl),
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

  Widget _sliverBox(Widget child) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: UiSpacing.md),
    sliver: SliverToBoxAdapter(child: child),
  );

  Widget _deckGroup(
    List<DeckRow> decks,
    Map<int, ({int due, int neu})>? counts,
  ) {
    final indices = {
      for (var index = 0; index < decks.length; index++)
        decks[index].deckId: index,
    };
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: UiSpacing.md),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final deck = decks[index];
            return Container(
              key: ValueKey(deck.deckId),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: index == 0 ? UiColors.border : UiColors.borderSubtle,
                  ),
                  bottom: index == decks.length - 1
                      ? const BorderSide(color: UiColors.border)
                      : BorderSide.none,
                ),
              ),
              child: _tile(
                label: deck.name.replaceAll('::', '  ›  '),
                due: counts == null ? null : counts[deck.deckId]?.due ?? 0,
                neu: counts == null ? null : counts[deck.deckId]?.neu ?? 0,
                onTap: () => widget.onStudyDeck(deck.deckId),
              ),
            );
          },
          childCount: decks.length,
          findChildIndexCallback: (key) =>
              key is ValueKey<int> ? indices[key.value] : null,
        ),
      ),
    );
  }

  void _setQuery(String value) => setState(() => _query = value);

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

/// The expansion state shares the optional section's lifecycle. Removing all
/// results or changing search mode recreates it just as the original tile did.
/// Its rows remain slivers in the screen's viewport instead of tile children.
class _OptionalDecks extends StatefulWidget {
  const _OptionalDecks({
    super.key,
    required this.searching,
    required this.initiallyExpanded,
    required this.count,
    required this.onExpansionChanged,
    required this.sliver,
  });

  final bool searching;
  final bool initiallyExpanded;
  final int count;
  final ValueChanged<bool> onExpansionChanged;
  final Widget sliver;

  @override
  State<_OptionalDecks> createState() => _OptionalDecksState();
}

class _OptionalDecksState extends State<_OptionalDecks> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    // The tile only holds the header now, so its expanded bottom border is
    // drawn after the rows, where the original tile's border sat.
    final tileTheme = ExpansionTileTheme.of(context);
    final expandedShape = tileTheme.shape;
    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            UiSpacing.md,
            UiSpacing.lg,
            UiSpacing.md,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: ExpansionTile(
              key: ValueKey('recall_optional_decks_${widget.searching}'),
              initiallyExpanded: _expanded,
              shape: tileTheme.collapsedShape,
              onExpansionChanged: (expanded) {
                setState(() => _expanded = expanded);
                widget.onExpansionChanged(expanded);
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
                    '${widget.count}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          widget.sliver,
          if (expandedShape is Border)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: UiSpacing.md),
              sliver: SliverToBoxAdapter(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(bottom: expandedShape.bottom),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
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

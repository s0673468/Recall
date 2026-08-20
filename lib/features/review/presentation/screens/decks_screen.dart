import 'package:flutter/material.dart';

import '../../../../core/widgets/recall_motion.dart';
import '../../../../core/widgets/recall_page_header.dart';
import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../data/recall_api.dart';

/// Pick a deck (or all decks) to study, with per-deck due/new counts. Tapping
/// starts a session on that deck and jumps to the Study tab.
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
        return RefreshIndicator(
          onRefresh: reload,
          child: FutureBuilder<Map<int, ({int due, int neu})>>(
            future: _counts,
            builder: (context, snap) {
              final counts = snap.data;
              final totalDue = counts?.values.fold(0, (a, b) => a + b.due);
              final totalNew = counts?.values.fold(0, (a, b) => a + b.neu);
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  UiSpacing.sm,
                  UiSpacing.md,
                  UiSpacing.sm,
                  UiSpacing.lg,
                ),
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: UiSpacing.sm,
                      vertical: UiSpacing.sm,
                    ),
                    child: RecallPageHeader(
                      title: 'Decks',
                      subtitle: 'Due and new cards by collection.',
                    ),
                  ),
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
                  _tile(
                    label: 'All decks',
                    icon: Icons.all_inclusive,
                    due: totalDue,
                    neu: totalNew,
                    onTap: () => widget.onStudyDeck(null),
                  ),
                  for (final d in decks)
                    _tile(
                      label: d.name.replaceAll('::', '  ›  '),
                      icon: Icons.folder_outlined,
                      due: counts?[d.deckId]?.due,
                      neu: counts?[d.deckId]?.neu,
                      onTap: () => widget.onStudyDeck(d.deckId),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _tile({
    required String label,
    required IconData icon,
    required int? due,
    required int? neu,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          key: ValueKey('recall_deck_row_$label'),
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: UiSpacing.md),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: UiColors.borderSubtle)),
          ),
          child: Row(
            children: [
              Icon(icon, color: UiColors.textMuted, size: 20),
              const SizedBox(width: UiSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: UiColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (due != null && due > 0) _count('$due due', UiColors.primary),
              if (neu != null && neu > 0) ...[
                const SizedBox(width: UiSpacing.sm),
                _count('$neu new', UiColors.chartBlue),
              ],
              const SizedBox(width: UiSpacing.xs),
              const Icon(
                Icons.chevron_right,
                color: UiColors.textMuted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _count(String n, Color color) => Text(
    n,
    style: TextStyle(
      color: color,
      fontFamily: 'monospace',
      fontSize: 11,
      fontWeight: FontWeight.w600,
    ),
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

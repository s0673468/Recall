import 'package:flutter/material.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart'
    show scopedPanelColor;

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
  State<DecksScreen> createState() => _DecksScreenState();
}

class _DecksScreenState extends State<DecksScreen> {
  late Future<Map<int, ({int due, int neu})>> _counts;

  @override
  void initState() {
    super.initState();
    _counts = widget.api.fetchDeckCounts();
  }

  Future<void> _reload() async {
    setState(() => _counts = widget.api.fetchDeckCounts());
    await _counts;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final decks = widget.controller.state.decks;
        return RefreshIndicator(
          onRefresh: _reload,
          child: FutureBuilder<Map<int, ({int due, int neu})>>(
            future: _counts,
            builder: (context, snap) {
              final counts = snap.data ?? const {};
              final totalDue = counts.values.fold(0, (a, b) => a + b.due);
              final totalNew = counts.values.fold(0, (a, b) => a + b.neu);
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  UiSpacing.sm,
                  UiSpacing.md,
                  UiSpacing.sm,
                  UiSpacing.lg,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UiSpacing.sm,
                      vertical: UiSpacing.sm,
                    ),
                    child: Text(
                      'Decks',
                      style: Theme.of(context).textTheme.headlineSmall,
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
                      due: counts[d.deckId]?.due ?? 0,
                      neu: counts[d.deckId]?.neu ?? 0,
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
    required int due,
    required int neu,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UiSpacing.xs,
        vertical: 5,
      ),
      child: Material(
        color: scopedPanelColor(context),
        borderRadius: BorderRadius.circular(UiRadius.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(UiRadius.lg),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UiSpacing.md,
              vertical: UiSpacing.md,
            ),
            child: Row(
              children: [
                Icon(icon, color: UiColors.primary, size: 22),
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
                if (due > 0) _count('$due', UiColors.primary),
                if (neu > 0) ...[
                  const SizedBox(width: 6),
                  _count('$neu', UiColors.chartBlue),
                ],
                const SizedBox(width: UiSpacing.sm),
                const Icon(
                  Icons.chevron_right,
                  color: UiColors.textMuted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _count(String n, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(UiRadii.pill),
    ),
    child: Text(
      n,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

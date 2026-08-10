import 'package:flutter/material.dart';
import 'package:health_anki_flutter/vendored/health_flutter_shared.dart'
    show UiScore;

import '../../../../core/platform/recall_platform.dart';
import '../../../../navigation/recall_page_route.dart';
import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';
import '../screens/primer_library_screen.dart';
import '../screens/primer_screen.dart';

/// The Stats "Concepts" section: the weakest METIS concept nodes by Again-rate
/// over the last fortnight, mirroring `metis recall-signal`. Shows the top-5
/// weakest ranked nodes, a coverage line, and graceful empty states.
///
/// The caller passes an already-computed [ranked] list (weakest first),
/// [notEnoughData] (nodes seen but below the rank floor), [coveredNodeCount]
/// (nodes with any review this fortnight) and [totalConcepts] (the graph size,
/// i.e. the resolved `concept_nodes` count). When [totalConcepts] is 0 the table
/// hasn't synced yet — the coverage denominator falls back to what we can see.
class ConceptRetentionPanel extends StatelessWidget {
  final List<NodeRetention> ranked;
  final int notEnoughData;
  final int coveredNodeCount;
  final int totalConcepts;
  final List<ConceptPage> conceptPages;
  final List<ConceptNodeInfo> conceptNodes;

  const ConceptRetentionPanel({
    super.key,
    required this.ranked,
    required this.notEnoughData,
    required this.coveredNodeCount,
    required this.totalConcepts,
    this.conceptPages = const [],
    this.conceptNodes = const [],
  });

  /// How many weakest nodes to surface.
  static const int _topN = 5;

  @override
  Widget build(BuildContext context) {
    final hasAnyData = coveredNodeCount > 0 || notEnoughData > 0;
    final pagesByNode = {for (final page in conceptPages) page.nodeId: page};
    return Container(
      key: const Key('recall_concepts_panel'),
      padding: const EdgeInsets.all(UiSpacing.md),
      decoration: BoxDecoration(
        color: UiColors.panel,
        borderRadius: BorderRadius.circular(UiRadii.group),
        border: Border.all(color: UiColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Concepts',
            style: TextStyle(
              color: UiColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UiSpacing.md),
          if (!hasAnyData)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UiSpacing.md),
              child: Text(
                'No concept-tagged reviews in this window yet.',
                style: TextStyle(color: UiColors.textMuted),
              ),
            )
          else ...[
            if (ranked.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: UiSpacing.sm),
                child: Text(
                  'Not enough reviews yet to rank any concept.',
                  style: TextStyle(color: UiColors.textMuted, fontSize: 12),
                ),
              )
            else
              for (final node in ranked.take(_topN))
                _row(context, node, pagesByNode[node.nodeId]),
            const SizedBox(height: UiSpacing.sm),
            _coverageLine(),
          ],
          if (conceptPages.isNotEmpty) ...[
            const SizedBox(height: UiSpacing.md),
            const Divider(color: UiColors.borderSubtle, height: 1),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  buildRecallPageRoute<void>(
                    nativeIos: recallRunsAsNativeIos(),
                    builder: (_) => PrimerLibraryScreen(
                      pages: conceptPages,
                      conceptNodes: conceptNodes,
                    ),
                  ),
                ),
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text('Browse concept primers'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, NodeRetention node, ConceptPage? page) {
    final row = _rowContent(node, showPrimerAffordance: page != null);
    if (page == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UiSpacing.xs),
        child: row,
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('recall_concept_primer_${node.nodeId}'),
        onTap: () => Navigator.of(context).push(
          buildRecallPageRoute<void>(
            nativeIos: recallRunsAsNativeIos(),
            builder: (_) =>
                PrimerScreen(page: page, conceptNodes: conceptNodes),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: UiSpacing.xs),
          child: row,
        ),
      ),
    );
  }

  Widget _rowContent(NodeRetention node, {required bool showPrimerAffordance}) {
    final color = UiScore.ratioTier(1 - node.againRate); // high again = poor
    final label = node.title ?? node.nodeId; // raw id is human-legible
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: UiColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (node.module != null && node.module!.isNotEmpty) ...[
                const SizedBox(height: 3),
                _moduleChip(node.module!),
              ],
            ],
          ),
        ),
        const SizedBox(width: UiSpacing.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${(node.againRate * 100).round()}%',
              style: TextStyle(
                color: color,
                fontFamily: 'monospace',
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'again · ${node.reviews} rev',
              style: const TextStyle(color: UiColors.textMuted, fontSize: 10),
            ),
          ],
        ),
        if (showPrimerAffordance) ...[
          const SizedBox(width: UiSpacing.xs),
          const Icon(Icons.chevron_right, color: UiColors.textMuted, size: 18),
        ],
      ],
    );
  }

  Widget _moduleChip(String module) => Container(
    padding: const EdgeInsets.symmetric(horizontal: UiSpacing.xs, vertical: 2),
    decoration: BoxDecoration(
      color: UiColors.secondary,
      borderRadius: BorderRadius.circular(UiRadii.pill),
    ),
    child: Text(
      module,
      style: const TextStyle(color: UiColors.textMuted, fontSize: 10),
    ),
  );

  Widget _coverageLine() {
    // Denominator = the graph size when the concept_nodes table has synced;
    // otherwise fall back to what we actually saw reviews for.
    final total = totalConcepts > 0 ? totalConcepts : coveredNodeCount;
    final parts = <String>[
      '$coveredNodeCount of $total concepts have review data this fortnight',
    ];
    if (notEnoughData > 0) {
      parts.add('$notEnoughData below the ranking floor');
    }
    return Text(
      parts.join(' · '),
      style: const TextStyle(color: UiColors.textMuted, fontSize: 11),
    );
  }
}

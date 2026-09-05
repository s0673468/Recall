import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
import '../../../../navigation/recall_page_route.dart';
import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';
import '../screens/primer_library_screen.dart';
import '../screens/primer_screen.dart';

/// The five weakest ranked concepts over the last fortnight, with coverage and
/// read-only links to the matching real primers.
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

  static const int _topN = 5;

  @override
  Widget build(BuildContext context) {
    final hasAnyData = coveredNodeCount > 0 || notEnoughData > 0;
    final pagesByNode = {for (final page in conceptPages) page.nodeId: page};
    return Padding(
      key: const Key('recall_concepts_panel'),
      padding: const EdgeInsets.symmetric(vertical: UiSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                  style: TextStyle(color: UiColors.textMuted),
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
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: const Text('Browse concept primers'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, NodeRetention node, ConceptPage? page) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
      child: _rowContent(context, node, showPrimerAffordance: page != null),
    );
    if (page == null) return row;
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
        child: row,
      ),
    );
  }

  Widget _rowContent(
    BuildContext context,
    NodeRetention node, {
    required bool showPrimerAffordance,
  }) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              node.title ?? node.nodeId,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (node.module?.isNotEmpty == true) ...[
              const SizedBox(height: UiSpacing.xs),
              Text(node.module!, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: UiSpacing.xs),
            Text(
              '${(node.againRate * 100).round()}% again · ${node.reviews} reviews',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      if (showPrimerAffordance) ...[
        const SizedBox(width: UiSpacing.sm),
        const Icon(Icons.chevron_right, color: UiColors.textMuted, size: 20),
      ],
    ],
  );

  Widget _coverageLine() {
    final total = totalConcepts > 0 ? totalConcepts : coveredNodeCount;
    final parts = <String>[
      '$coveredNodeCount of $total concepts have review data this fortnight',
    ];
    if (notEnoughData > 0) {
      parts.add('$notEnoughData below the ranking floor');
    }
    return Text(
      parts.join(' · '),
      style: const TextStyle(
        color: UiColors.textMuted,
        fontSize: 12,
        height: 1.6,
      ),
    );
  }
}

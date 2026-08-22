import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
import '../../../../core/widgets/recall_page_header.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../navigation/recall_page_route.dart';
import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';
import 'primer_screen.dart';

/// Read-only library of every available primer, grouped by concept module.
class PrimerLibraryScreen extends StatelessWidget {
  final List<ConceptPage> pages;
  final List<ConceptNodeInfo> conceptNodes;

  const PrimerLibraryScreen({
    super.key,
    required this.pages,
    required this.conceptNodes,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: UiColors.canvas,
    appBar: AppBar(
      backgroundColor: UiColors.canvas,
      foregroundColor: UiColors.textPrimary,
      elevation: 0,
      title: const Text('Concept primers'),
    ),
    body: ColoredBox(
      color: UiColors.canvas,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            UiSpacing.md,
            UiSpacing.lg,
            UiSpacing.md,
            UiSpacing.xl,
          ),
          children: [
            const RecallPageHeader(
              eyebrow: 'Learning',
              title: 'Concept primers',
              subtitle:
                  'Readable explanations for the ideas behind your cards.',
            ),
            const SizedBox(height: UiSpacing.lg),
            PrimerLibraryContent(pages: pages, conceptNodes: conceptNodes),
          ],
        ),
      ),
    ),
  );
}

/// Reusable grouped primer rows for the standalone library and Read tab.
class PrimerLibraryContent extends StatefulWidget {
  final List<ConceptPage> pages;
  final List<ConceptNodeInfo> conceptNodes;

  const PrimerLibraryContent({
    super.key,
    required this.pages,
    required this.conceptNodes,
  });

  @override
  State<PrimerLibraryContent> createState() => _PrimerLibraryContentState();
}

class _PrimerLibraryContentState extends State<PrimerLibraryContent> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moduleByNode = {
      for (final node in widget.conceptNodes) node.nodeId: node.module,
    };
    final query = _query.trim().toLowerCase();
    final pages = query.isEmpty
        ? widget.pages
        : widget.pages.where((page) {
            final module = moduleByNode[page.nodeId] ?? '';
            return page.title.toLowerCase().contains(query) ||
                module.toLowerCase().contains(query);
          });
    final grouped = <String, List<ConceptPage>>{};
    for (final page in pages) {
      final module = moduleByNode[page.nodeId];
      (grouped[module == null || module.isEmpty ? 'Other' : module] ??= []).add(
        page,
      );
    }
    final modules = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'Other') return 1;
        if (b == 'Other') return -1;
        return a.compareTo(b);
      });
    for (final group in grouped.values) {
      group.sort((a, b) => a.title.compareTo(b.title));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UiSpacing.sm,
            UiSpacing.sm,
            UiSpacing.sm,
            UiSpacing.xs,
          ),
          child: Material(
            color: Colors.transparent,
            child: TextField(
              key: const Key('recall_primer_search'),
              controller: _searchController,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Search primers',
                hintText: 'Title or module',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        ),
        if (modules.isEmpty)
          Padding(
            padding: const EdgeInsets.all(UiSpacing.md),
            child: Text(
              query.isEmpty
                  ? 'No primers available.'
                  : 'No primers match your search.',
              style: const TextStyle(color: UiColors.textMuted),
            ),
          ),
        for (final module in modules) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UiSpacing.sm,
              UiSpacing.md,
              UiSpacing.sm,
              UiSpacing.xs,
            ),
            child: Text(
              module,
              style: const TextStyle(
                color: UiColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          RecallListGroup(
            children: [
              for (final page in grouped[module]!)
                PrimerRow(
                  page: page,
                  onTap: () => Navigator.of(context).push(
                    buildRecallPageRoute<void>(
                      nativeIos: recallRunsAsNativeIos(),
                      builder: (_) => PrimerScreen(
                        page: page,
                        conceptNodes: widget.conceptNodes,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class PrimerRow extends StatelessWidget {
  final ConceptPage page;
  final VoidCallback onTap;

  const PrimerRow({super.key, required this.page, required this.onTap});

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey('recall_primer_row_${page.nodeId}'),
    child: RecallListRow(
      icon: Icons.menu_book_outlined,
      title: page.title,
      onTap: onTap,
    ),
  );
}

import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
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
      backgroundColor: UiColors.sidebar,
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
      ],
    );
  }
}

class PrimerRow extends StatelessWidget {
  final ConceptPage page;
  final VoidCallback onTap;

  const PrimerRow({super.key, required this.page, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Container(
        key: ValueKey('recall_primer_row_${page.nodeId}'),
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: UiSpacing.sm),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: UiColors.borderSubtle)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.menu_book_outlined,
              color: UiColors.textMuted,
              size: 18,
            ),
            const SizedBox(width: UiSpacing.md),
            Expanded(
              child: Text(
                page.title,
                style: const TextStyle(
                  color: UiColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
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

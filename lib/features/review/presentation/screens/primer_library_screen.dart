import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../navigation/recall_page_route.dart';
import '../../../../theme/ui_tokens.dart';
import '../../domain/stats_models.dart';
import 'primer_screen.dart';

/// Read-only library of every available primer, ordered by concept module.
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
    appBar: AppBar(title: const Text('Concept primers')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(
              UiSpacing.md,
              UiSpacing.md,
              UiSpacing.md,
              UiSpacing.xl,
            ),
            children: [
              PrimerLibraryContent(pages: pages, conceptNodes: conceptNodes),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The full library remains searchable even when the Read tab omits concepts
/// already shown above it from the default browse list.
class PrimerLibraryContent extends StatefulWidget {
  final List<ConceptPage> pages;
  final List<ConceptNodeInfo> conceptNodes;
  final Set<String> browseExcludedNodeIds;
  final ValueChanged<String>? onQueryChanged;

  const PrimerLibraryContent({
    super.key,
    required this.pages,
    required this.conceptNodes,
    this.browseExcludedNodeIds = const {},
    this.onQueryChanged,
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

  void _setQuery(String value) {
    setState(() => _query = value);
    widget.onQueryChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final moduleByNode = {
      for (final node in widget.conceptNodes) node.nodeId: node.module,
    };
    final query = _query.trim().toLowerCase();
    final pages =
        widget.pages.where((page) {
          if (query.isEmpty) {
            return !widget.browseExcludedNodeIds.contains(page.nodeId);
          }
          final module = moduleByNode[page.nodeId] ?? '';
          return page.title.toLowerCase().contains(query) ||
              module.toLowerCase().contains(query);
        }).toList()..sort((a, b) {
          final moduleA = moduleByNode[a.nodeId] ?? '';
          final moduleB = moduleByNode[b.nodeId] ?? '';
          if (moduleA.isEmpty != moduleB.isEmpty) {
            return moduleA.isEmpty ? 1 : -1;
          }
          final moduleOrder = moduleA.compareTo(moduleB);
          return moduleOrder == 0 ? a.title.compareTo(b.title) : moduleOrder;
        });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: TextField(
            key: const Key('recall_primer_search'),
            controller: _searchController,
            autocorrect: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Find a concept',
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
        ),
        const SizedBox(height: UiSpacing.sm),
        if (pages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
            child: Text(
              query.isNotEmpty
                  ? 'No primers match your search.'
                  : widget.pages.isEmpty
                  ? 'No primers available.'
                  : 'All available primers are shown above.',
              style: const TextStyle(color: UiColors.textMuted),
            ),
          )
        else
          RecallListGroup(
            children: [
              for (final page in pages)
                PrimerRow(
                  page: page,
                  module: moduleByNode[page.nodeId],
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
    );
  }
}

class PrimerRow extends StatelessWidget {
  final ConceptPage page;
  final String? module;
  final VoidCallback onTap;

  const PrimerRow({
    super.key,
    required this.page,
    this.module,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey('recall_primer_row_${page.nodeId}'),
    child: RecallListRow(
      title: page.title,
      subtitle: module?.isNotEmpty == true ? module : null,
      onTap: onTap,
    ),
  );
}

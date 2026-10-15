import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../navigation/recall_page_route.dart';
import '../../../../theme/ui_tokens.dart';
import '../../domain/concept_attribution.dart';
import '../../domain/stats_models.dart';
import 'primer_screen.dart';

/// Read-only library of every available primer, ordered by concept module.
class PrimerLibraryScreen extends StatelessWidget {
  final List<ConceptPage> pages;
  final List<ConceptNodeInfo> conceptNodes;
  final ValueChanged<ConceptPage>? onOpenPrimer;

  const PrimerLibraryScreen({
    super.key,
    required this.pages,
    required this.conceptNodes,
    this.onOpenPrimer,
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
          child: PrimerLibraryContent._owningViewport(
            pages: pages,
            conceptNodes: conceptNodes,
            onOpenPrimer: onOpenPrimer,
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
  final ValueChanged<ConceptPage>? onOpenPrimer;
  final bool collapsedBrowse;
  final bool _ownsViewport;

  const PrimerLibraryContent({
    super.key,
    required this.pages,
    required this.conceptNodes,
    this.browseExcludedNodeIds = const {},
    this.onQueryChanged,
    this.onOpenPrimer,
    this.collapsedBrowse = false,
  }) : _ownsViewport = false;

  const PrimerLibraryContent._owningViewport({
    required this.pages,
    required this.conceptNodes,
    this.onOpenPrimer,
  }) : browseExcludedNodeIds = const {},
       onQueryChanged = null,
       collapsedBrowse = false,
       _ownsViewport = true;

  @override
  State<PrimerLibraryContent> createState() => _PrimerLibraryContentState();
}

class _PrimerLibraryContentState extends State<PrimerLibraryContent> {
  final _searchController = TextEditingController();
  String _query = '';
  bool _browseExpanded = false;

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
          // Chat syntheses follow the curriculum modules.
          final chatA = moduleA == ConceptAttribution.chatModule;
          final chatB = moduleB == ConceptAttribution.chatModule;
          if (chatA != chatB) return chatA ? 1 : -1;
          if (chatA) return b.updatedAt.compareTo(a.updatedAt);
          final moduleOrder = moduleA.compareTo(moduleB);
          return moduleOrder == 0 ? a.title.compareTo(b.title) : moduleOrder;
        });

    final controls = Column(
      key: const ValueKey('recall_primer_library_controls'),
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
        if (widget.collapsedBrowse && query.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('recall_primer_browse_toggle'),
              onPressed: () =>
                  setState(() => _browseExpanded = !_browseExpanded),
              icon: Icon(
                _browseExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(_browseExpanded ? 'Hide library' : 'Browse library'),
            ),
          ),
      ],
    );
    final empty = Padding(
      padding: const EdgeInsets.symmetric(vertical: UiSpacing.md),
      child: Text(
        query.isNotEmpty
            ? 'No primers match your search.'
            : widget.pages.isEmpty
            ? 'No primers available.'
            : widget.collapsedBrowse
            ? 'All available primers are in your reading list.'
            : 'All available primers are shown above.',
        style: const TextStyle(color: UiColors.textMuted),
      ),
    );
    PrimerRow buildRow(ConceptPage page) => PrimerRow(
      page: page,
      module: moduleByNode[page.nodeId],
      onTap: () => widget.onOpenPrimer != null
          ? widget.onOpenPrimer!(page)
          : Navigator.of(context).push(
              buildRecallPageRoute<void>(
                nativeIos: recallRunsAsNativeIos(),
                builder: (_) =>
                    PrimerScreen(page: page, conceptNodes: widget.conceptNodes),
              ),
            ),
    );

    if (widget._ownsViewport) {
      final rowIndices = {
        for (var index = 0; index < pages.length; index++)
          ValueKey('recall_primer_list_item_${pages[index].nodeId}'): index + 1,
      };
      // This builder owns the screen's viewport. A nested shrink-wrapped list
      // would still lay out every primer inside the outer scrolling child.
      return ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          UiSpacing.md,
          UiSpacing.md,
          UiSpacing.md,
          UiSpacing.xl,
        ),
        itemCount: pages.isEmpty ? 2 : pages.length + 1,
        semanticChildCount: pages.length,
        addSemanticIndexes: false,
        findChildIndexCallback: (key) =>
            key == const ValueKey('recall_primer_library_controls')
            ? 0
            : rowIndices[key],
        itemBuilder: (context, index) {
          if (index == 0) return controls;
          if (pages.isEmpty) return empty;
          final page = pages[index - 1];
          return IndexedSemantics(
            key: ValueKey('recall_primer_list_item_${page.nodeId}'),
            index: index - 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (index == 1)
                  const Divider(height: 1, color: UiColors.border),
                buildRow(page),
                Divider(
                  height: 1,
                  color: index == pages.length
                      ? UiColors.border
                      : UiColors.borderSubtle,
                ),
              ],
            ),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        controls,
        if (query.isNotEmpty || !widget.collapsedBrowse || _browseExpanded)
          if (pages.isEmpty)
            empty
          else
            RecallListGroup(
              children: [for (final page in pages) buildRow(page)],
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

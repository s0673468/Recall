import 'package:flutter/material.dart';

import '../../../../navigation/recall_page_route.dart';
import '../../application/stats_service.dart';
import '../../data/recall_api.dart';
import '../../domain/concept_attribution.dart';
import '../../domain/stats_models.dart';
import '../screens/primer_screen.dart';

/// An optional read-only detour. The retained Study controller owns the card;
/// neither choosing a page nor returning from it performs a study action.
class StudyReadingAction extends StatefulWidget {
  final RecallApi api;
  final String? tags;
  final bool nativeIos;

  const StudyReadingAction({
    super.key,
    required this.api,
    required this.tags,
    required this.nativeIos,
  });

  @override
  State<StudyReadingAction> createState() => _StudyReadingActionState();
}

class _StudyReadingActionState extends State<StudyReadingAction> {
  late Future<({List<ConceptPage> pages, List<ConceptNodeInfo> nodes})> _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant StudyReadingAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.api != oldWidget.api) _load();
  }

  void _load() {
    final service = StatsService(widget.api);
    _data =
        Future.wait<Object>([
          service.loadConceptPages(),
          service.loadConceptNodes(),
        ]).then(
          (data) => (
            pages: data[0] as List<ConceptPage>,
            nodes: data[1] as List<ConceptNodeInfo>,
          ),
        );
  }

  Future<void> _open(
    List<ConceptPage> pages,
    List<ConceptNodeInfo> nodes,
  ) async {
    final page = pages.length == 1
        ? pages.single
        : await showModalBottomSheet<ConceptPage>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final page in pages)
                    ListTile(
                      title: Text(page.title),
                      onTap: () => Navigator.pop(context, page),
                    ),
                ],
              ),
            ),
          );
    if (page == null || !mounted) return;
    await Navigator.of(context).push(
      buildRecallPageRoute<void>(
        nativeIos: widget.nativeIos,
        builder: (_) => PrimerScreen(page: page, conceptNodes: nodes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<({List<ConceptPage> pages, List<ConceptNodeInfo> nodes})>(
        future: _data,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null || snapshot.hasError) return const SizedBox.shrink();
          final pages = ConceptAttribution.readingPages(
            widget.tags,
            data.pages,
          );
          if (pages.isEmpty) return const SizedBox.shrink();
          return Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('recall_read_explanation'),
              onPressed: () => _open(pages, data.nodes),
              child: const Text('Read explanation'),
            ),
          );
        },
      );
}

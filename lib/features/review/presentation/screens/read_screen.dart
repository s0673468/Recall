import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../application/stats_service.dart';
import '../../data/recall_api.dart';
import '../../domain/stats_models.dart';
import 'primer_library_screen.dart';
import 'primer_screen.dart';

typedef _ReadData = ({
  List<ReviewLogEntry> reviewLog,
  Map<String, String> noteTags,
  List<ConceptNodeInfo> conceptNodes,
  List<ConceptPage> conceptPages,
});

/// Daily concept reading followed by the complete grouped primer library.
class ReadScreen extends StatefulWidget {
  final RecallApi api;

  const ReadScreen({super.key, required this.api});

  @override
  State<ReadScreen> createState() => ReadScreenState();
}

class ReadScreenState extends State<ReadScreen> {
  late final StatsService _service = StatsService(widget.api);
  late Future<_ReadData> _data;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    _data = () async {
      final results = await Future.wait<Object>([
        _service.loadReviewLog(),
        _service.loadNoteTags(),
        _service.loadConceptNodes(),
        _service.loadConceptPages(),
      ]);
      return (
        reviewLog: results[0] as List<ReviewLogEntry>,
        noteTags: results[1] as Map<String, String>,
        conceptNodes: results[2] as List<ConceptNodeInfo>,
        conceptPages: results[3] as List<ConceptPage>,
      );
    }();
  }

  Future<void> reload() async {
    setState(_fetch);
    await _data.catchError(
      (_) => (
        reviewLog: <ReviewLogEntry>[],
        noteTags: <String, String>{},
        conceptNodes: <ConceptNodeInfo>[],
        conceptPages: <ConceptPage>[],
      ),
    );
  }

  void _openPrimer(ConceptPage page, List<ConceptNodeInfo> conceptNodes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PrimerScreen(page: page, conceptNodes: conceptNodes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: reload,
    child: FutureBuilder<_ReadData>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [
              SizedBox(height: UiSpacing.xl),
              Center(child: CircularProgressIndicator()),
            ],
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(UiSpacing.md),
            children: const [
              Text(
                'Could not load reading.',
                style: TextStyle(color: UiColors.textMuted),
              ),
            ],
          );
        }

        final data = snapshot.data!;
        final todayPages = StatsService.todayConceptPages(
          reviewLog: data.reviewLog,
          noteTags: data.noteTags,
          conceptPages: data.conceptPages,
          today: DateTime.now(),
        );
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            UiSpacing.md,
            UiSpacing.md,
            UiSpacing.md,
            UiSpacing.xl,
          ),
          children: [
            Text('Read', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: UiSpacing.lg),
            Text('Today', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: UiSpacing.xs),
            if (todayPages.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: UiSpacing.sm,
                  vertical: UiSpacing.md,
                ),
                child: Text(
                  'Nothing studied yet today — the library is below.',
                  style: TextStyle(color: UiColors.textMuted),
                ),
              )
            else
              for (final page in todayPages)
                PrimerRow(
                  page: page,
                  onTap: () => _openPrimer(page, data.conceptNodes),
                ),
            const SizedBox(height: UiSpacing.lg),
            Text('Library', style: Theme.of(context).textTheme.titleMedium),
            PrimerLibraryContent(
              pages: data.conceptPages,
              conceptNodes: data.conceptNodes,
            ),
          ],
        );
      },
    ),
  );
}

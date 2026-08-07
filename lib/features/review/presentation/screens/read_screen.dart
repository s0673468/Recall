import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../theme/ui_tokens.dart';
import '../../application/remediation_service.dart';
import '../../application/stats_service.dart';
import '../../data/local_review_store.dart';
import '../../data/recall_api.dart';
import '../../domain/concept_attribution.dart';
import '../../domain/stats_models.dart';
import 'primer_library_screen.dart';
import 'primer_screen.dart';
import '../widgets/remediation_rows.dart';

typedef _ReadData = ({
  List<ReviewLogEntry> reviewLog,
  Map<String, String> noteTags,
  List<ConceptNodeInfo> conceptNodes,
  List<ConceptPage> conceptPages,
  List<LocalRemediationItem> remediation,
});

/// Daily concept reading followed by the complete grouped primer library.
class ReadScreen extends StatefulWidget {
  final RecallApi api;
  final LocalReviewStore store;

  ReadScreen({super.key, required this.api, LocalReviewStore? store})
    : store = store ?? LocalReviewStore();

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
        widget.store.remediationQueue(),
      ]);
      return (
        reviewLog: results[0] as List<ReviewLogEntry>,
        noteTags: results[1] as Map<String, String>,
        conceptNodes: results[2] as List<ConceptNodeInfo>,
        conceptPages: results[3] as List<ConceptPage>,
        remediation: results[4] as List<LocalRemediationItem>,
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
        remediation: <LocalRemediationItem>[],
      ),
    );
  }

  Future<void> _openPrimer(
    ConceptPage page,
    List<ConceptNodeInfo> conceptNodes, {
    bool remediation = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PrimerScreen(page: page, conceptNodes: conceptNodes),
      ),
    );
    if (!remediation) return;
    await widget.store.completeRemediation(page.nodeId);
    if (mounted) setState(_fetch);
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
        final todayPages = ConceptAttribution.todayConceptPages(
          reviewLog: data.reviewLog,
          noteTags: data.noteTags,
          conceptPages: data.conceptPages,
          today: DateTime.now(),
        );
        final rereadPages = visibleRemediationPages(
          queue: data.remediation,
          conceptNodes: data.conceptNodes,
          conceptPages: data.conceptPages,
          readTodayPages: todayPages,
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
            if (rereadPages.isNotEmpty)
              RemediationRows(
                pages: rereadPages,
                onTap: (page) => unawaited(
                  _openPrimer(page, data.conceptNodes, remediation: true),
                ),
              ),
            if (rereadPages.isNotEmpty && todayPages.isNotEmpty)
              const SizedBox(height: UiSpacing.md),
            if (todayPages.isEmpty && rereadPages.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: UiSpacing.sm,
                  vertical: UiSpacing.md,
                ),
                child: Text(
                  'Nothing studied yet today — the library is below.',
                  style: TextStyle(color: UiColors.textMuted),
                ),
              ),
            if (todayPages.isNotEmpty)
              for (final page in todayPages)
                PrimerRow(
                  page: page,
                  onTap: () => unawaited(_openPrimer(page, data.conceptNodes)),
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

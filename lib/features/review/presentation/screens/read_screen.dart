import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/platform/recall_platform.dart';
import '../../../../core/widgets/recall_motion.dart';
import '../../../../core/widgets/recall_page_header.dart';
import '../../../../core/widgets/recall_surfaces.dart';
import '../../../../navigation/recall_page_route.dart';
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
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    _searching = false;
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
      buildRecallPageRoute<void>(
        nativeIos: recallRunsAsNativeIos(),
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
        late final Widget content;
        if (snapshot.connectionState != ConnectionState.done) {
          content = ListView(
            key: const ValueKey('read_loading'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              UiSpacing.md,
              UiSpacing.md,
              UiSpacing.md,
              UiSpacing.xl,
            ),
            children: const [
              SizedBox(height: UiSpacing.xl),
              Center(child: CircularProgressIndicator()),
            ],
          );
        } else if (snapshot.hasError || !snapshot.hasData) {
          content = ListView(
            key: const ValueKey('read_error'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(UiSpacing.md),
            children: const [
              RecallPageHeader(title: 'Read'),
              SizedBox(height: UiSpacing.xl),
              RecallStatePanel(
                icon: Icons.cloud_off_outlined,
                title: 'Could not load reading',
                message: 'Pull down to try loading your primers again.',
              ),
            ],
          );
        } else {
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
          final moduleByNode = {
            for (final node in data.conceptNodes) node.nodeId: node.module,
          };
          content = ListView(
            key: const ValueKey('read_content'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              UiSpacing.md,
              UiSpacing.md,
              UiSpacing.md,
              UiSpacing.xl,
            ),
            children: [
              const RecallPageHeader(title: 'Read'),
              const SizedBox(height: UiSpacing.lg),
              Visibility(
                visible: !_searching,
                maintainState: true,
                child: Column(
                  key: const Key('recall_read_today_hero'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const RecallSectionLabel(title: 'Today’s reading'),
                    const SizedBox(height: UiSpacing.xs),
                    Text(
                      'Connected to your recent reviews.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: UiColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: UiSpacing.md),
                    if (rereadPages.isNotEmpty)
                      RemediationRows(
                        pages: rereadPages,
                        onTap: (page) => unawaited(
                          _openPrimer(
                            page,
                            data.conceptNodes,
                            remediation: true,
                          ),
                        ),
                      ),
                    if (rereadPages.isNotEmpty && todayPages.isNotEmpty)
                      const SizedBox(height: UiSpacing.md),
                    if (todayPages.isEmpty && rereadPages.isEmpty)
                      const Text(
                        'Nothing studied yet today. Your full library is ready below.',
                        style: TextStyle(color: UiColors.textMuted),
                      ),
                    if (todayPages.isNotEmpty)
                      RecallListGroup(
                        children: [
                          for (final page in todayPages)
                            PrimerRow(
                              page: page,
                              module: moduleByNode[page.nodeId],
                              onTap: () => unawaited(
                                _openPrimer(page, data.conceptNodes),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: UiSpacing.xl),
                  ],
                ),
              ),
              RecallSectionLabel(
                title: _searching ? 'Library' : 'More from the library',
              ),
              const SizedBox(height: UiSpacing.md),
              PrimerLibraryContent(
                pages: data.conceptPages,
                conceptNodes: data.conceptNodes,
                browseExcludedNodeIds: {
                  for (final page in todayPages) page.nodeId,
                  for (final page in rereadPages) page.nodeId,
                },
                onQueryChanged: (query) {
                  final searching = query.trim().isNotEmpty;
                  if (searching != _searching) {
                    setState(() => _searching = searching);
                  }
                },
              ),
            ],
          );
        }
        return RecallMotionSwap(child: content);
      },
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../theme/ui_tokens.dart';
import '../../application/review_controller.dart';
import '../../data/local_review_store.dart';
import '../../data/recall_api.dart';
import '../../domain/concept_attribution.dart';
import '../../domain/stats_models.dart';
import '../screens/primer_screen.dart';
import '../screens/read_screen.dart';

/// A persistent reading companion: opening a primer never navigates away from
/// Study. The shell keeps this mounted when hidden so reading position and
/// search survive a resize or tab change.
class DesktopReadingPane extends StatefulWidget {
  final ReviewController controller;
  final RecallApi api;
  final LocalReviewStore store;

  const DesktopReadingPane({
    super.key,
    required this.controller,
    required this.api,
    required this.store,
  });

  @override
  State<DesktopReadingPane> createState() => _DesktopReadingPaneState();
}

class _DesktopReadingPaneState extends State<DesktopReadingPane> {
  final _readKey = GlobalKey<ReadScreenState>();
  final _focusNode = FocusNode(debugLabel: 'Desktop reading');
  ConceptPage? _page;
  List<ConceptNodeInfo> _conceptNodes = const [];
  Completer<void>? _readingFinished;
  late int _remediationRevision;

  @override
  void initState() {
    super.initState();
    _remediationRevision = widget.controller.remediationRevision;
    widget.controller.addListener(_onReviewChanged);
  }

  @override
  void didUpdateWidget(DesktopReadingPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onReviewChanged);
      _remediationRevision = widget.controller.remediationRevision;
      widget.controller.addListener(_onReviewChanged);
    }
  }

  void _onReviewChanged() {
    if (_remediationRevision != widget.controller.remediationRevision) {
      _remediationRevision = widget.controller.remediationRevision;
      unawaited(_readKey.currentState?.reload());
    }
    setState(() {});
  }

  Future<void> _openPrimer(
    ConceptPage page,
    List<ConceptNodeInfo> conceptNodes,
  ) {
    // Existing Read behavior completes remediation only when reading returns.
    _readingFinished?.complete();
    final finished = Completer<void>();
    _readingFinished = finished;
    setState(() {
      _page = page;
      _conceptNodes = conceptNodes;
    });
    _focusNode.requestFocus();
    return finished.future;
  }

  void _backToReading() {
    setState(() => _page = null);
    _readingFinished?.complete();
    _readingFinished = null;
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onReviewChanged);
    // Do not finish a remediation read when the entire workspace is disposed.
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    // Text fields receive their own keys first. Unhandled study shortcuts stop
    // here while keyboard focus is in reading, including the primer body.
    onKeyEvent: (_, event) =>
        event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.digit1 ||
            event.logicalKey == LogicalKeyboardKey.digit2 ||
            event.logicalKey == LogicalKeyboardKey.digit3 ||
            event.logicalKey == LogicalKeyboardKey.digit4
        ? KeyEventResult.skipRemainingHandlers
        : KeyEventResult.ignored,
    child: Listener(
      onPointerDown: (_) {
        if (!_focusNode.hasFocus) _focusNode.requestFocus();
      },
      child: DecoratedBox(
        key: const Key('recall_desktop_reading_pane'),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: UiColors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UiSpacing.md,
                UiSpacing.md,
                UiSpacing.md,
                UiSpacing.sm,
              ),
              child: Row(
                children: [
                  if (_page != null) ...[
                    IconButton(
                      key: const Key('recall_reading_back'),
                      tooltip: 'Back to reading',
                      onPressed: _backToReading,
                      icon: const Icon(Icons.arrow_back, size: 20),
                    ),
                    const SizedBox(width: UiSpacing.xs),
                  ],
                  Text(
                    'Reading',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  if (_page == null)
                    IconButton(
                      tooltip: 'Refresh reading',
                      onPressed: () => unawaited(
                        _readKey.currentState?.reload(refresh: true),
                      ),
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Offstage(
                    offstage: _page != null,
                    child: ReadScreen(
                      key: _readKey,
                      api: widget.api,
                      store: widget.store,
                      showHeader: false,
                      libraryFirst: true,
                      relatedNodeIds: ConceptAttribution.nodeTags(
                        widget.controller.state.current?.tags,
                      ),
                      onOpenPrimer: _openPrimer,
                    ),
                  ),
                  if (_page case final page?)
                    Positioned.fill(
                      child: PrimerContent(
                        key: ValueKey('reading_primer_${page.nodeId}'),
                        page: page,
                        conceptNodes: _conceptNodes,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

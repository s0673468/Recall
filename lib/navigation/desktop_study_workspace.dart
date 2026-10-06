import 'package:flutter/material.dart';

import '../features/review/application/review_controller.dart';
import '../features/review/data/recall_api.dart';
import '../features/review/presentation/widgets/desktop_reading_pane.dart';
import '../theme/ui_tokens.dart';

/// A bounded study desk with equal space for studying and reading.
/// Keep both children mounted after first use, including across rotation.
class DesktopStudyWorkspace extends StatefulWidget {
  final bool enabled;
  final bool nativeAndroid;
  final ReviewController controller;
  final RecallApi api;
  final Widget study;

  const DesktopStudyWorkspace({
    super.key,
    required this.enabled,
    this.nativeAndroid = false,
    required this.controller,
    required this.api,
    required this.study,
  });

  @override
  State<DesktopStudyWorkspace> createState() => _DesktopStudyWorkspaceState();
}

class _DesktopStudyWorkspaceState extends State<DesktopStudyWorkspace> {
  bool _readingMounted = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final size = MediaQuery.sizeOf(context);
      final desktop =
          widget.enabled && !widget.nativeAndroid && size.width >= 840;
      // Use logical window dimensions, not a device model or pixel resolution.
      // The short-side guard excludes a cover screen/ordinary landscape phone.
      // Local width accounts for the rail, system insets and multi-window mode.
      final gap = widget.nativeAndroid ? UiSpacing.md : UiSpacing.xl;
      final androidSplit =
          size.width > size.height &&
          size.shortestSide >= 600 &&
          constraints.maxWidth >= 680 * (scale < 1 ? 1 : scale) + gap;
      final split =
          widget.enabled &&
          scale < 1.6 &&
          (widget.nativeAndroid ? androidSplit : constraints.maxWidth >= 1000);
      // Android does not fetch a second reading library until the companion is
      // first visible. Once used, retain its primer/search/scroll when folded.
      _readingMounted |= widget.enabled && (!widget.nativeAndroid || split);
      final readingWidth = split
          ? (constraints.maxWidth - (desktop ? UiSpacing.md * 2 : 0) - gap) / 2
          : 0.0;
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: desktop ? UiSpacing.md : 0,
          vertical: desktop ? UiSpacing.md : 0,
        ),
        child: Row(
          key: const Key('recall_study_workspace'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              key: const Key('recall_study_column'),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: desktop || split ? 640 : double.infinity,
                    maxHeight: desktop ? 640 : double.infinity,
                  ),
                  child: SizedBox.expand(child: widget.study),
                ),
              ),
            ),
            SizedBox(width: split ? gap : 0),
            if (_readingMounted)
              SizedBox(
                key: const Key('recall_reading_column'),
                width: readingWidth,
                child: Offstage(
                  offstage: !split,
                  child: OverflowBox(
                    minWidth: split ? readingWidth : 380,
                    maxWidth: split ? readingWidth : 380,
                    alignment: Alignment.topLeft,
                    child: FocusScope(
                      canRequestFocus: split,
                      child: DesktopReadingPane(
                        controller: widget.controller,
                        api: widget.api,
                        store: widget.controller.store,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

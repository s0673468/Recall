import 'package:flutter/material.dart';

import '../features/review/application/review_controller.dart';
import '../features/review/data/recall_api.dart';
import '../features/review/presentation/widgets/desktop_reading_pane.dart';
import '../theme/ui_tokens.dart';

/// A bounded study desk: the card stays primary, reading sits alongside it.
/// Keep both children mounted when the browser narrows or changes tabs.
class DesktopStudyWorkspace extends StatelessWidget {
  final bool enabled;
  final ReviewController controller;
  final RecallApi api;
  final Widget study;

  const DesktopStudyWorkspace({
    super.key,
    required this.enabled,
    required this.controller,
    required this.api,
    required this.study,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final desktop = enabled && MediaQuery.sizeOf(context).width >= 840;
      final split = enabled && constraints.maxWidth >= 1000 && scale < 1.6;
      final readingWidth = split
          ? (constraints.maxWidth * .38).clamp(360.0, 460.0)
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
                    maxWidth: enabled ? 640 : double.infinity,
                    maxHeight: desktop ? 640 : double.infinity,
                  ),
                  child: SizedBox.expand(child: study),
                ),
              ),
            ),
            SizedBox(width: split ? UiSpacing.xl : 0),
            if (enabled)
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
                        controller: controller,
                        api: api,
                        store: controller.store,
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/desktop_reading_pane.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  final state = ReviewState(
    loading: false,
    queue: [
      ReviewCard.fromRow({
        'id': 1,
        'guid': 'synthetic-card',
        'notes': {
          'front': 'Synthetic study question',
          'back': 'Synthetic study answer',
          'tags': 'node::vectors',
        },
      }),
    ],
  );

  @override
  int get remediationRevision => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture controller call');
}

void main() {
  setUpAll(() async {
    await loadVisualFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    // Deterministic substitute for Android's system sans in widget captures.
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Medium.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Bold.ttf')))
        .load();
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('synthetic Reading snapshots at ${width.toInt()}px', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime(2026, 10, 24, 12);
      final api = FakeRecallApi([])
        ..conceptPages = [
          for (final entry in {
            'vectors': 'Vector geometry',
            'models': 'Models and generalization',
            'chat-synthetic': 'Connecting ideas from this week',
          }.entries)
            ConceptPage(
              nodeId: entry.key,
              title: entry.value,
              bodyHtml: '<p>Synthetic concept explanation.</p>',
              updatedAt: now,
            ),
        ]
        ..conceptNodes = const [
          ConceptNodeInfo(
            nodeId: 'vectors',
            title: 'Vectors',
            module: 'M00-synthetic-foundations',
          ),
          ConceptNodeInfo(
            nodeId: 'models',
            title: 'Models',
            module: 'M01-synthetic-learning',
          ),
        ]
        ..reviewLog = [
          ReviewLogEntry(guid: 'synthetic-note', at: now, rating: 3),
        ]
        ..noteTags = {'synthetic-note': 'node::vectors'};
      final controller = _Controller();
      addTearDown(controller.dispose);

      Future<void> show({bool fullRead = false}) async {
        final reading = fullRead
            ? ReadScreen(api: api, clock: () => now)
            : DesktopReadingPane(
                controller: controller,
                api: api,
                store: LocalReviewStore(),
                clock: () => now,
              );
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            theme: buildRecallTheme(),
            home: RepaintBoundary(
              key: const Key('reading_declutter_capture'),
              child: Banner(
                message: 'SYNTHETIC PREVIEW',
                location: BannerLocation.bottomStart,
                textStyle: const TextStyle(
                  fontFamily: 'Roboto',
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
                child: Scaffold(
                  body: width < 840
                      ? reading
                      : Row(
                          children: [
                            const Expanded(
                              child: Center(
                                child: Text('Synthetic Study fixture'),
                              ),
                            ),
                            SizedBox(width: 440, child: reading),
                          ],
                        ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> capture(String state) async {
        expect(tester.takeException(), isNull, reason: state);
        final phase = Platform.environment['RECALL_READING_VISUAL_PHASE'];
        if (phase == null) return;
        // Repaint retained text layers before capturing the reused boundary.
        void repaint(RenderObject object) {
          object.markNeedsPaint();
          object.visitChildren(repaint);
        }

        repaint(
          tester.renderObject(
            find.byKey(const Key('reading_declutter_capture')),
          ),
        );
        await tester.pump();
        await expectLater(
          find.byKey(const Key('reading_declutter_capture')),
          matchesGoldenFile(
            Uri.file(
              '${Directory.current.path}/.tmp/reading-declutter/'
              '$phase-${width.toInt()}-$state.png',
            ),
          ),
        );
      }

      await show();
      await capture('companion-idle');
      final search = find.byKey(const Key('recall_primer_search'));
      await tester.enterText(search, 'Models');
      await tester.pumpAndSettle();
      await capture('companion-results');
      await tester.enterText(search, 'unmatched synthetic query');
      await tester.pumpAndSettle();
      await capture('companion-no-results');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      await capture('companion-cleared');
      await show(fullRead: true);
      await capture('full-read');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

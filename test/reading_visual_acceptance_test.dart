import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/desktop_reading_pane.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

// All content and preferences are synthetic. No Supabase client is initialized.
class _ReadingApi extends FakeRecallApi {
  _ReadingApi()
    : super(
        [],
        decks: const [
          DeckRow(
            deckId: 1,
            name: 'Learning::Long curriculum for unfamiliar examples',
          ),
        ],
      );

  Completer<List<ConceptPage>>? pendingPages;
  Completer<List<ReviewLogEntry>>? pendingLog;

  @override
  Future<List<ConceptPage>> fetchConceptPages() =>
      pendingPages?.future ?? super.fetchConceptPages();

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) =>
      pendingLog?.future ?? super.fetchReviewLog(days: days);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadVisualFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final family in [
      'Main',
      'Math',
      'AMS',
      'Size1',
      'Size2',
      'Size3',
      'Size4',
    ]) {
      final loader = FontLoader('packages/flutter_math_fork/KaTeX_$family');
      loader.addFont(
        rootBundle.load(
          'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_$family-${family == 'Math' ? 'Italic' : 'Regular'}.ttf',
        ),
      );
      if (family == 'Main' || family == 'Math') {
        loader.addFont(
          rootBundle.load(
            'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_$family-Italic.ttf',
          ),
        );
      }
      await loader.load();
    }
    // Match the system sans family deterministically using a bundled font.
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Medium.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Bold.ttf')))
        .load();
  });

  for (final size in const [Size(360, 800), Size(412, 915), Size(1280, 800)]) {
    testWidgets('reading acceptance ${size.width.toInt()} at text scale 1.3', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Keep fixtures and date-sensitive screens on the baseline's Saturday.
      final now = DateTime(2026, 10, 24, 12);
      final pages = [
        ConceptPage(
          nodeId: 'vectors',
          title: 'Vector geometry and projections onto unfamiliar directions',
          bodyHtml:
              '<p>A projection measures how much of a vector points along another direction.</p>'
              '<p>Use a unit direction to compare components on the same scale.</p>'
              r'<p>For a unit vector \(u\), the projection is \((x \cdot u)u\).</p>',
          updatedAt: now,
        ),
        ConceptPage(
          nodeId: 'chat-synthetic-week',
          title: 'Connecting probability, uncertainty and everyday decisions',
          bodyHtml: '<p>Synthetic weekly discussion summary.</p>',
          updatedAt: now,
        ),
        ConceptPage(
          nodeId: 'models',
          title: 'Models and generalization to unseen examples',
          bodyHtml: '<p>Compare predictions on unseen examples.</p>',
          updatedAt: now,
        ),
      ];
      final api = _ReadingApi()
        ..conceptPages = pages
        ..conceptNodes = const [
          ConceptNodeInfo(
            nodeId: 'vectors',
            title: 'Vectors',
            module: 'M00 · Mathematical foundations',
          ),
          ConceptNodeInfo(
            nodeId: 'models',
            title: 'Models',
            module: 'M01 · Machine learning',
          ),
          ConceptNodeInfo(
            nodeId: 'chat-synthetic-week',
            title: 'Weekly notes',
            module: 'From your chats',
          ),
        ]
        ..reviewLog = [
          for (var day = 0; day < 40; day++)
            ReviewLogEntry(
              guid: 'synthetic-vector',
              at: now.subtract(Duration(days: day)),
              rating: day % 5 == 0 ? 1 : 3,
              dueAfter: now.add(const Duration(days: 4)),
            ),
        ]
        ..noteTags = {'synthetic-vector': 'node::vectors'};
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      final prefs = RecallPrefsController(api: api);
      final reminder = StudyReminderController();
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      addTearDown(reminder.dispose);
      await controller.load();
      await prefs.load();

      Future<void> show(
        Widget screen, {
        bool settle = true,
        bool bounded = false,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            theme: buildRecallTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: KeyedSubtree(
              key: UniqueKey(),
              child: PageStorage(
                bucket: PageStorageBucket(),
                child: RepaintBoundary(
                  key: const Key('reading_capture'),
                  child: bounded
                      ? Scaffold(
                          body: SafeArea(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 820,
                                ),
                                child: screen,
                              ),
                            ),
                          ),
                        )
                      : screen,
                ),
              ),
            ),
          ),
        );
        if (settle) {
          await tester.pumpAndSettle();
        } else {
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      Future<void> capture(String scene) async {
        // Repaint reused text layers before capturing an offscreen boundary.
        void repaint(RenderObject object) {
          object.markNeedsPaint();
          object.visitChildren(repaint);
        }

        repaint(tester.renderObject(find.byKey(const Key('reading_capture'))));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: scene);
        final phase = Platform.environment['RECALL_VISUAL_PHASE'] ?? 'after';
        await expectLater(
          find.byKey(const Key('reading_capture')),
          matchesGoldenFile(
            '../reports/visual-20261024/$phase/${size.width.toInt()}-$scene.png',
          ),
        );
      }

      await show(ReadScreen(api: api, clock: () => now), bounded: true);
      await capture('reading-chats');
      expect(find.text('From your chats'), findsOneWidget);
      await show(
        Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: size.width > 840 ? 420 : size.width,
              child: DesktopReadingPane(
                controller: controller,
                api: api,
                store: LocalReviewStore(),
                clock: () => now,
              ),
            ),
          ),
        ),
      );
      await capture('reading-panel');
      expect(
        tester.getSize(find.byTooltip('Refresh reading')).shortestSide,
        greaterThanOrEqualTo(48),
      );
      expect(
        find.byKey(const Key('recall_primer_browse_toggle')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'Vector',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const Key('recall_primer_row_vectors')))
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text(pages.first.title));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byTooltip('Back to reading')).shortestSide,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byTooltip('Back to reading'));
      await tester.pumpAndSettle();
      await show(
        PrimerLibraryScreen(pages: pages, conceptNodes: api.conceptNodes),
      );
      await capture('library');
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'unmatched synthetic query',
      );
      await tester.pumpAndSettle();
      await capture('library-no-results');
      expect(
        tester.getSize(find.byTooltip('Clear search')).shortestSide,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text(pages.first.title), findsOneWidget);
      await show(
        PrimerScreen(page: pages.first, conceptNodes: api.conceptNodes),
      );
      await capture('primer');
      expect(
        tester.getTopLeft(find.text(pages.first.title)).dx,
        size.width < 600 ? UiSpacing.md : (size.width - 720) / 2 + UiSpacing.lg,
      );
      await show(
        SettingsScreen(
          prefs: prefs,
          controller: controller,
          reminder: reminder,
        ),
      );
      await capture('settings');
      for (final tooltip in [
        'Decrease New cards / day',
        'Increase New cards / day',
      ]) {
        expect(
          tester.getSize(find.byTooltip(tooltip)).shortestSide,
          greaterThanOrEqualTo(48),
        );
      }
      await tester.drag(find.byType(ListView).first, const Offset(0, -450));
      await tester.pumpAndSettle();
      await capture('settings-lower');
      await tester.ensureVisible(find.text('Per-deck new-card limits'));
      await tester.tap(find.text('Per-deck new-card limits'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Set override'));
      await tester.tap(find.text('Set override'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use default'));
      await tester.pumpAndSettle();
      await capture('settings-expanded');
      expect(
        tester
            .getTopLeft(
              find.text('Learning  ›  Long curriculum for unfamiliar examples'),
            )
            .dx,
        tester.getTopLeft(find.text('Per-deck new-card limits')).dx,
      );
      await show(
        StatsScreen(api: api, controller: controller, clock: () => now),
        bounded: true,
      );
      await capture('stats');
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -210),
      );
      await tester.pumpAndSettle();
      await capture('stats-activity');
      expect(tester.widget<Text>(find.text('Less')).style?.fontSize, 12);
      expect(
        tester.getTopRight(find.text('More')).dx,
        tester.getTopRight(find.byType(ReviewHeatmap)).dx,
      );
      await show(
        ReadScreen(api: _ReadingApi(), clock: () => now),
        bounded: true,
      );
      await capture('reading-empty');
      expect(find.text('No recent reading yet.'), findsOneWidget);
      await show(
        ReadScreen(api: _ReadingApi()..failReviewLog = true, clock: () => now),
        bounded: true,
      );
      await capture('reading-error');
      final pending = Completer<List<ConceptPage>>();
      await show(
        ReadScreen(
          api: _ReadingApi()..pendingPages = pending,
          clock: () => now,
        ),
        bounded: true,
        settle: false,
      );
      await capture('reading-loading');
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Loading primers…'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .semanticsLabel,
        'Loading primers',
      );
      pending.complete([]);
      await tester.pumpAndSettle();
      await show(const PrimerLibraryScreen(pages: [], conceptNodes: []));
      await capture('library-empty');
      await show(
        StatsScreen(
          api: _ReadingApi(),
          controller: controller,
          clock: () => now,
        ),
        bounded: true,
      );
      await capture('stats-empty');
      await show(
        StatsScreen(
          api: _ReadingApi()
            ..failReviewLog = true
            ..failDueDates = true,
          controller: controller,
          clock: () => now,
        ),
        bounded: true,
      );
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      await capture('stats-error');
      final pendingLog = Completer<List<ReviewLogEntry>>();
      await show(
        StatsScreen(
          api: _ReadingApi()..pendingLog = pendingLog,
          controller: controller,
          clock: () => now,
        ),
        bounded: true,
        settle: false,
      );
      await capture('stats-loading');
      pendingLog.complete([]);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

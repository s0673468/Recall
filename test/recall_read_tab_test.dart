import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_read_cache.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Read tab', () {
    const node = ConceptNodeInfo(
      nodeId: 'm00-vector-geometry',
      title: 'Vector geometry',
      module: 'M00',
    );

    Future<void> pumpShell(WidgetTester tester, FakeRecallApi api) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      final prefs = RecallPrefsController(api: api);
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: AppShell(
            controller: controller,
            api: api,
            prefs: prefs,
            linkSource: SilentLinkSource(),
            nativeIos: false,
          ),
        ),
      );
      // At the default 800x600 Android test size, unfolded Study has its own
      // persistent companion and the rail shows icons. Select the visible tab
      // control; a hidden rail label is not a tap target.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(Icons.menu_book_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        3,
      );
    }

    Finder inReadTab(Finder finder) => find.descendant(
      of: find.byKey(const ValueKey('recall_tab_opacity_3')),
      matching: finder,
    );

    testWidgets('primer library search filters titles and modules', (
      tester,
    ) async {
      final pages = [
        ConceptPage(
          nodeId: node.nodeId,
          title: 'Vector geometry primer',
          bodyHtml: 'Projection',
          updatedAt: DateTime.utc(2026, 7, 29),
        ),
        ConceptPage(
          nodeId: 'm01-attention',
          title: 'Attention primer',
          bodyHtml: 'Queries and keys',
          updatedAt: DateTime.utc(2026, 7, 29),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PrimerLibraryContent(
                pages: pages,
                conceptNodes: const [
                  node,
                  ConceptNodeInfo(
                    nodeId: 'm01-attention',
                    title: 'Attention',
                    module: 'M01',
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.text('Attention primer'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'attention',
      );
      await tester.pump();

      expect(find.text('Vector geometry primer'), findsNothing);
      expect(find.text('Attention primer'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'M00',
      );
      await tester.pump();
      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.text('Attention primer'), findsNothing);
    });

    testWidgets('shows a primer reviewed today above the library search', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final api = FakeRecallApi([testCard()])
        ..reviewLog = [
          ReviewLogEntry(guid: 'g1', at: DateTime.now(), rating: 3),
        ]
        ..noteTags = const {'g1': 'node::m00-vector-geometry'}
        ..conceptNodes = const [node]
        ..conceptPages = [page];

      await pumpShell(tester, api);

      expect(inReadTab(find.byType(ReadScreen)), findsOneWidget);
      expect(inReadTab(find.text('Recent reading')), findsOneWidget);
      expect(inReadTab(find.text('Library')), findsOneWidget);
      expect(inReadTab(find.text('More from the library')), findsNothing);
      expect(inReadTab(find.text('Vector geometry primer')), findsOneWidget);
      expect(inReadTab(find.text('M00')), findsNothing);
      expect(
        inReadTab(find.text('From what you reviewed in the last 3 days.')),
        findsNothing,
      );
      expect(
        inReadTab(
          find.text(
            'Nothing reviewed in the last 3 days. Your full library is ready below.',
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('shows recent chat syntheses in their own section', (
      tester,
    ) async {
      const chatNode = ConceptNodeInfo(
        nodeId: 'chat-2026-w40-entropy',
        title: 'Entropy, from your chats',
        module: 'From your chats',
      );
      final chatPage = ConceptPage(
        nodeId: chatNode.nodeId,
        title: 'Entropy, from your chats',
        bodyHtml: '<p>Entropy</p>',
        updatedAt: DateTime.now().toUtc(),
      );
      final primer = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final api = FakeRecallApi([testCard()])
        ..conceptNodes = const [node, chatNode]
        ..conceptPages = [primer, chatPage];

      await pumpShell(tester, api);

      expect(inReadTab(find.text('From your chats')), findsWidgets);
      expect(
        inReadTab(find.byKey(const Key('recall_read_chats'))),
        findsOneWidget,
      );
      expect(inReadTab(find.text('Entropy, from your chats')), findsOneWidget);
      expect(inReadTab(find.text('Vector geometry primer')), findsNothing);
      await tester.enterText(
        inReadTab(find.byKey(const Key('recall_primer_search'))),
        'Vector',
      );
      await tester.pumpAndSettle();
      expect(inReadTab(find.text('Vector geometry primer')), findsOneWidget);
      expect(inReadTab(find.text('Entropy, from your chats')), findsNothing);
    });

    testWidgets('keeps unreviewed library primers hidden until searched', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final api = FakeRecallApi([testCard()])
        ..reviewLog = [
          ReviewLogEntry(
            guid: 'g1',
            at: DateTime.now().subtract(const Duration(days: 3)),
            rating: 3,
          ),
        ]
        ..noteTags = const {'g1': 'node::m00-vector-geometry'}
        ..conceptNodes = const [node]
        ..conceptPages = [page];

      await pumpShell(tester, api);

      expect(inReadTab(find.text('No recent reading yet.')), findsOneWidget);
      expect(inReadTab(find.text('Vector geometry primer')), findsNothing);
      await tester.enterText(
        inReadTab(find.byKey(const Key('recall_primer_search'))),
        'Vector',
      );
      await tester.pumpAndSettle();
      expect(inReadTab(find.text('Vector geometry primer')), findsOneWidget);
      await tester.tap(inReadTab(find.byTooltip('Clear search')));
      await tester.pumpAndSettle();
      expect(inReadTab(find.text('Vector geometry primer')), findsNothing);
      expect(inReadTab(find.text('M00')), findsNothing);
    });

    testWidgets('shows queued reread rows and clears one after reading', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime(2026, 7, 29),
      );
      final api = FakeRecallApi(const [])
        ..conceptNodes = const [node]
        ..conceptPages = [page];
      final store = LocalReviewStore();
      await store.enqueueRemediation([node.nodeId]);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: ReadScreen(api: api, store: store),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reread: Vector geometry primer'), findsOneWidget);
      await tester.tap(find.text('Reread: Vector geometry primer'));
      await tester.pumpAndSettle();
      expect(find.byType(PrimerScreen), findsOneWidget);

      Navigator.of(tester.element(find.byType(PrimerScreen))).pop();
      await tester.pumpAndSettle();
      expect(await store.remediationQueue(), isEmpty);
    });

    testWidgets('does not reread a primer already attributed today', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime(2026, 7, 29),
      );
      final api = FakeRecallApi(const [])
        ..reviewLog = [
          ReviewLogEntry(guid: 'g1', at: DateTime.now(), rating: 3),
        ]
        ..noteTags = const {'g1': 'node::m00-vector-geometry'}
        ..conceptNodes = const [node]
        ..conceptPages = [page];
      final store = LocalReviewStore();
      await store.enqueueRemediation([node.nodeId]);

      await tester.pumpWidget(
        MaterialApp(
          home: ReadScreen(api: api, store: store),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reread: Vector geometry primer'), findsNothing);
      expect(find.text('Vector geometry primer'), findsOneWidget);
    });
  });

  group('Shared read cache', () {
    Future<ReviewController> pumpShell(
      WidgetTester tester,
      FakeRecallApi api,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      final prefs = RecallPrefsController(api: api);
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            controller: controller,
            api: api,
            prefs: prefs,
            linkSource: SilentLinkSource(),
            nativeIos: false,
            nativeAndroid: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    Future<void> openTab(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    int longLogReads(FakeRecallApi api) => api.reviewLogReads
        .where((days) => days == StatsService.reviewLogDays)
        .length;

    testWidgets('Stats and Read share one read; revisits reuse it', (
      tester,
    ) async {
      final api = FakeRecallApi([testCard(), testCard(id: 2)]);
      await pumpShell(tester, api);
      // Both tabs mount at startup and load together.
      expect(longLogReads(api), 1);
      expect(api.conceptPageReads, 1);

      await openTab(tester, 'Stats');
      await openTab(tester, 'Read');
      await openTab(tester, 'Study');
      await openTab(tester, 'Stats');
      expect(longLogReads(api), 1);
      expect(api.conceptPageReads, 1);
    });

    testWidgets('a delivered review refreshes the log on the next visit', (
      tester,
    ) async {
      final api = FakeRecallApi([testCard(), testCard(id: 2)]);
      final controller = await pumpShell(tester, api);
      expect(longLogReads(api), 1);

      controller.flip();
      await controller.rate(Rating.good);
      await tester.pumpAndSettle();
      expect(api.applied, hasLength(1));

      await openTab(tester, 'Stats');
      expect(longLogReads(api), 2);
      // Concept metadata does not depend on reviews and stays shared.
      expect(api.conceptPageReads, 1);
      await openTab(tester, 'Read');
      expect(longLogReads(api), 2);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    test('signing out drops the shared reads', () async {
      SharedPreferences.setMockInitialValues({});
      final api = GatedFsrsRecallApi([testCard()]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      addTearDown(api.authStates.close);
      final cache = RecallReadCache.of(api);
      var loads = 0;
      Future<int> load() async => ++loads;
      await cache.read('concept_pages', load);
      await cache.read('concept_pages', load);
      expect(loads, 1);

      api.authStates.add(const AuthState(AuthChangeEvent.signedOut, null));
      await Future<void>.delayed(Duration.zero);
      await cache.read('concept_pages', load);
      expect(loads, 2);
    });
  });
}

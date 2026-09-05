import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

class _DeckController extends ChangeNotifier implements ReviewController {
  @override
  final ReviewState state = const ReviewState(
    loading: false,
    decks: [
      DeckRow(deckId: 11, name: 'Machine learning::Models and generalization'),
      DeckRow(deckId: 22, name: 'Opt-in::Portuguese'),
    ],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LibraryApi implements RecallApi {
  bool failCounts = false;
  List<ReviewLogEntry> reviewLog = [];
  final pages = [
    ConceptPage(
      nodeId: 'vectors',
      title: 'Vector geometry',
      bodyHtml: 'A vector has magnitude and direction.',
      updatedAt: DateTime(2026, 9, 5),
    ),
    ConceptPage(
      nodeId: 'models',
      title: 'Models and generalization',
      bodyHtml: 'A model should work on unseen examples.',
      updatedAt: DateTime(2026, 9, 5),
    ),
  ];
  final nodes = const [
    ConceptNodeInfo(nodeId: 'vectors', title: 'Vector geometry', module: 'M00'),
    ConceptNodeInfo(nodeId: 'models', title: 'Models', module: 'M01'),
  ];

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async {
    if (failCounts) throw StateError('Counts unavailable');
    return {11: (due: 1234, neu: 5), 22: (due: 83, neu: 2)};
  }

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async =>
      reviewLog;

  @override
  Future<Map<String, String>> fetchNoteTags() async => {'g1': 'node::vectors'};

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => nodes;

  @override
  Future<List<ConceptPage>> fetchConceptPages() async => pages;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  void phone(WidgetTester tester, {double width = 390}) {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpDecks(
    WidgetTester tester,
    _LibraryApi api,
    ValueChanged<int?> onStudyDeck, {
    double textScale = 1,
  }) async {
    final controller = _DeckController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: DecksScreen(
            controller: controller,
            api: api,
            onStudyDeck: onStudyDeck,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'search finds collapsed optional decks and keeps selection identity',
    (tester) async {
      phone(tester);
      final selected = <int?>[];
      await pumpDecks(tester, _LibraryApi(), selected.add);

      expect(find.text('Opt-in  ›  Portuguese'), findsNothing);
      expect(find.text('Your core decks · 1234 due · 5 new'), findsOneWidget);
      await tester.tap(find.text('Start review'));
      expect(selected, [null]);
      await tester.enterText(
        find.byKey(const Key('recall_deck_search')),
        'Portuguese',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('recall_deck_hero')), findsNothing);
      expect(find.text('Opt-in  ›  Portuguese'), findsOneWidget);
      expect(find.text('83 due'), findsOneWidget);
      await tester.tap(find.text('Opt-in  ›  Portuguese'));
      expect(selected, [null, 22]);
      await tester.enterText(
        find.byKey(const Key('recall_deck_search')),
        'not a deck',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching decks.'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Start review'), findsOneWidget);
      expect(find.text('Opt-in  ›  Portuguese'), findsNothing);
      await tester.tap(find.text('Optional curricula'));
      await tester.pumpAndSettle();
      expect(find.text('Opt-in  ›  Portuguese'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deck search and complete names fit a small phone at double text size',
    (tester) async {
      phone(tester, width: 320);
      final selected = <int?>[];
      await pumpDecks(tester, _LibraryApi(), selected.add, textScale: 2);
      await tester.enterText(
        find.byKey(const Key('recall_deck_search')),
        'generalization',
      );
      await tester.pumpAndSettle();
      final row = find.text('Machine learning  ›  Models and generalization');
      await tester.ensureVisible(row);
      await tester.tap(row);
      expect(selected, [11]);
      expect(find.text('1234 due · 5 new'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown counts stay unknown and retry restores the totals', (
    tester,
  ) async {
    phone(tester);
    final api = _LibraryApi()..failCounts = true;
    await pumpDecks(tester, api, (_) {});
    expect(find.text('Could not load deck counts.'), findsOneWidget);
    expect(find.text('Your core decks · — due · — new'), findsOneWidget);
    expect(find.textContaining('0 due'), findsNothing);
    api.failCounts = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Your core decks · 1234 due · 5 new'), findsOneWidget);
  });

  testWidgets(
    'Read shows today once and search still reaches the full library',
    (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues({});
      final api = _LibraryApi()
        ..reviewLog = [
          ReviewLogEntry(guid: 'g1', at: DateTime.now(), rating: 3),
        ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: ReadScreen(api: api, store: LocalReviewStore()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Vector geometry'), findsOneWidget);
      expect(find.text('Models and generalization'), findsOneWidget);
      expect(find.text('Today’s reading'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'M00',
      );
      await tester.pumpAndSettle();
      expect(find.text('Today’s reading'), findsNothing);
      expect(find.text('Vector geometry'), findsOneWidget);
      expect(find.text('Models and generalization'), findsNothing);
      await tester.tap(find.text('Vector geometry'));
      await tester.pumpAndSettle();
      expect(find.byType(PrimerScreen), findsOneWidget);
      expect(
        find.text('A vector has magnitude and direction.'),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.byType(PrimerScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Today’s reading'), findsOneWidget);
      expect(find.text('Vector geometry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the all-today library is empty only while browsing', (
    tester,
  ) async {
    final api = _LibraryApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PrimerLibraryContent(
              pages: api.pages,
              conceptNodes: api.nodes,
              browseExcludedNodeIds: const {'vectors', 'models'},
            ),
          ),
        ),
      ),
    );
    expect(find.text('All available primers are shown above.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('recall_primer_search')),
      'vector',
    );
    await tester.pumpAndSettle();
    expect(find.text('Vector geometry'), findsOneWidget);
    expect(find.text('All available primers are shown above.'), findsNothing);
  });

  testWidgets(
    'a long primer remains scrollable at 320px and double text size',
    (tester) async {
      phone(tester, width: 320);
      final page = ConceptPage(
        nodeId: 'long-reading',
        title: 'A long concept title that needs several lines',
        bodyHtml: List.generate(
          18,
          (index) =>
              '<p>Paragraph $index explains a real relationship in detail.</p>',
        ).join(),
        updatedAt: DateTime(2026, 9, 5),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: PrimerScreen(page: page, conceptNodes: const []),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(1000));
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(100));
      expect(tester.takeException(), isNull);
    },
  );
}

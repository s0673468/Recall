import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/desktop_reading_pane.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  ReviewState state = ReviewState(
    loading: false,
    queue: [
      ReviewCard.fromRow({
        'id': 101,
        'guid': 'synthetic-card',
        'notes': {
          'front': 'Study question',
          'back': 'Study answer',
          'tags': 'node::vectors node::none',
        },
      }),
    ],
  );

  @override
  int remediationRevision = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store extends LocalReviewStore {
  int completions = 0;

  @override
  Future<bool> completeRemediation(String nodeId, {DateTime? now}) {
    completions++;
    return super.completeRemediation(nodeId, now: now);
  }
}

class _Api implements RecallApi {
  bool fail = false;
  int pageReads = 0;

  final pages = [
    ConceptPage(
      nodeId: 'vectors',
      title: 'Vector geometry',
      bodyHtml: List.generate(
        35,
        (i) => 'Vector paragraph $i.',
      ).join('<br><br>'),
      updatedAt: DateTime.now(),
    ),
    ConceptPage(
      nodeId: 'models',
      title: 'Generalization',
      bodyHtml: 'Use unseen examples.',
      updatedAt: DateTime.now(),
    ),
    ConceptPage(
      nodeId: 'chat-example',
      title: 'Weekly discussion',
      bodyHtml: 'Synthetic discussion summary.',
      updatedAt: DateTime.now(),
    ),
  ];

  @override
  Future<List<ConceptPage>> fetchConceptPages() async {
    pageReads++;
    if (fail) throw StateError('Synthetic offline failure');
    return pages;
  }

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => const [
    ConceptNodeInfo(nodeId: 'vectors', title: 'Vector geometry', module: 'M00'),
    ConceptNodeInfo(nodeId: 'models', title: 'Generalization', module: 'M01'),
  ];

  @override
  Future<Map<String, String>> fetchNoteTags() async => {};

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Api api;
  late _Controller controller;
  late _Store store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _Api();
    controller = _Controller();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpPane(
    WidgetTester tester, {
    FocusOnKeyEventCallback? onKey,
    List<String> rereadNodeIds = const [],
  }) async {
    store = _Store();
    await store.enqueueRemediation(rereadNodeIds);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: Scaffold(
          body: Focus(
            onKeyEvent: onKey,
            child: Row(
              children: [
                const Expanded(child: Text('Study question')),
                SizedBox(
                  width: 440,
                  child: DesktopReadingPane(
                    controller: controller,
                    api: api,
                    store: store,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('related concept opens inline and preserves the active card', (
    tester,
  ) async {
    await pumpPane(tester);
    expect(find.text('For this card'), findsOneWidget);
    expect(find.text('From your chats'), findsOneWidget);
    expect(find.text('Recent reading'), findsOneWidget);
    final originalCard = controller.state.current;
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('recall_read_related')),
        matching: find.text('Vector geometry'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PrimerContent), findsOneWidget);
    expect(find.byType(PrimerScreen), findsNothing);
    expect(find.text('Study question'), findsOneWidget);
    expect(controller.state.current, same(originalCard));
    expect(controller.state.showBack, isFalse);
    await tester.tap(find.byKey(const Key('recall_reading_back')));
    await tester.pumpAndSettle();
    expect(find.text('For this card'), findsOneWidget);
    expect(find.byType(PrimerContent), findsNothing);
  });

  testWidgets(
    'companion search precedes recent reading and browse starts collapsed',
    (tester) async {
      await pumpPane(tester);
      expect(
        tester.getTopLeft(find.byKey(const Key('recall_primer_search'))).dy,
        lessThan(tester.getTopLeft(find.text('From your chats')).dy),
      );
      expect(find.byKey(const Key('recall_primer_row_models')), findsNothing);
      await tester.tap(find.byKey(const Key('recall_primer_browse_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recall_primer_row_models')), findsOneWidget);
      await tester.tap(find.byKey(const Key('recall_primer_browse_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recall_primer_row_models')), findsNothing);
    },
  );

  testWidgets('library search and scroll survive inline reading', (
    tester,
  ) async {
    await pumpPane(tester);
    final search = find.byKey(const Key('recall_primer_search'));
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Generalization');
    await tester.pumpAndSettle();
    expect(find.text('For this card'), findsNothing);
    await tester.tap(find.byKey(const Key('recall_primer_row_models')));
    await tester.pumpAndSettle();
    expect(find.text('Use unseen examples.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recall_reading_back')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, 'Generalization');
    expect(find.byKey(const Key('recall_primer_row_models')), findsOneWidget);
    expect(find.text('For this card'), findsNothing);
  });

  testWidgets('typing and reading shortcuts do not bubble into Study', (
    tester,
  ) async {
    var studyKeys = 0;
    await pumpPane(
      tester,
      onKey: (_, event) {
        if (event is KeyDownEvent &&
            [
              LogicalKeyboardKey.space,
              LogicalKeyboardKey.digit1,
            ].contains(event.logicalKey)) {
          studyKeys++;
        }
        return KeyEventResult.ignored;
      },
    );
    final search = find.byKey(const Key('recall_primer_search'));
    await tester.ensureVisible(search);
    await tester.tap(search);
    await tester.enterText(search, 'Vector geometry 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(search).controller!.text,
      'Vector geometry 1',
    );
    expect(studyKeys, 0);
    expect(controller.state.showBack, isFalse);
    expect(controller.state.reviewedThisSession, 0);
  });

  testWidgets('card changes keep the open primer and its reading position', (
    tester,
  ) async {
    await pumpPane(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('recall_read_related')),
        matching: find.text('Vector geometry'),
      ),
    );
    await tester.pumpAndSettle();
    final primerScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PrimerContent),
        matching: find.byType(Scrollable),
      ),
    );
    primerScroll.position.jumpTo(300);
    await tester.pump();
    controller.state = controller.state.copyWith(showBack: true, index: 1);
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(PrimerContent), findsOneWidget);
    expect(primerScroll.position.pixels, 300);
    await tester.tap(find.byKey(const Key('recall_reading_back')));
    await tester.pumpAndSettle();
    expect(find.text('For this card'), findsNothing);
  });

  testWidgets('a new remediation refresh preserves the library query', (
    tester,
  ) async {
    await pumpPane(tester);
    final search = find.byKey(const Key('recall_primer_search'));
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Generalization');
    await tester.pumpAndSettle();
    await store.enqueueRemediation(['vectors']);
    controller.remediationRevision++;
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, 'Generalization');
    expect(find.byKey(const Key('recall_primer_row_models')), findsOneWidget);
    expect(find.text('For this card'), findsNothing);
    expect(find.text('Reread: Vector geometry'), findsNothing);
  });

  testWidgets('reading errors offer a working retry', (tester) async {
    api.fail = true;
    await pumpPane(tester);
    expect(find.text('Could not load reading'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.byKey(const Key('recall_read_retry')));
    await tester.pumpAndSettle();
    expect(find.text('Could not load reading'), findsNothing);
    expect(find.text('For this card'), findsOneWidget);
    expect(api.pageReads, 2);
  });

  testWidgets(
    'reread finishes in the existing local remediation queue on back',
    (tester) async {
      await pumpPane(tester, rereadNodeIds: ['models']);
      await tester.tap(find.text('Reread: Generalization'));
      await tester.pumpAndSettle();
      expect(await store.remediationQueue(), hasLength(1));
      await tester.tap(find.byKey(const Key('recall_reading_back')));
      await tester.pumpAndSettle();
      expect(await store.remediationQueue(), isEmpty);
      expect(store.completions, 1);
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(store.completions, 1);
      expect(find.text('Reread: Generalization'), findsNothing);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

class _DeckController extends ChangeNotifier implements ReviewController {
  _DeckController(List<DeckRow> decks)
    : state = ReviewState(loading: false, decks: decks);

  @override
  final ReviewState state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountsApi implements RecallApi {
  _CountsApi(this.decks);

  final List<DeckRow> decks;
  int calls = 0;
  bool fail = false;

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async {
    calls++;
    if (fail) throw StateError('Invented count failure');
    return {
      for (var index = 0; index < decks.length; index++)
        decks[index].deckId: (due: index + 1, neu: 2),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_CountsApi> _pumpDecks(
  WidgetTester tester,
  List<DeckRow> decks, {
  _CountsApi? api,
  ValueChanged<int?>? onStudyDeck,
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = _DeckController(decks);
  addTearDown(controller.dispose);
  final counts = api ?? _CountsApi(decks);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: DecksScreen(
          controller: controller,
          api: counts,
          onStudyDeck: onStudyDeck ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return counts;
}

void main() {

  testWidgets('counts remain unknown until retry and refresh uses one request', (
    tester,
  ) async {
    const decks = [DeckRow(deckId: 11, name: 'Invented core::Only deck')];
    final api = _CountsApi(decks)..fail = true;
    await _pumpDecks(tester, decks, api: api);
    expect(api.calls, 1);
    expect(find.text('Your core decks · — due · — new'), findsOneWidget);
    expect(find.text('Could not load deck counts.'), findsOneWidget);

    api.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(api.calls, 2);
    expect(find.text('Your core decks · 1 due · 2 new'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(api.calls, 3);
    expect(tester.takeException(), isNull);
  });
}

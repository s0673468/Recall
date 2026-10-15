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

List<DeckRow> _decks({bool optional = false, bool longLastName = false}) => [
  for (var index = 0; index < 500; index++)
    DeckRow(
      deckId: 10000 + index,
      name:
          '${optional ? 'Opt-in' : 'Invented core'}::Deck '
          '${index.toString().padLeft(4, '0')}'
          '${longLastName && index == 499 ? ' with a synthetic long name that wraps on a narrow display' : ''}',
    ),
];

String _label(DeckRow deck) => deck.name.replaceAll('::', '  ›  ');
Finder _row(DeckRow deck) =>
    find.byKey(ValueKey('recall_deck_row_${_label(deck)}'));

int _mountedRows() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return widget is KeyedSubtree &&
      key is ValueKey<String> &&
      key.value.startsWith('recall_deck_row_') &&
      key.value != 'recall_deck_row_Automatic review';
}).evaluate().length;

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
  testWidgets('500 core decks mount only the current viewport and cache', (
    tester,
  ) async {
    final decks = _decks();
    final api = await _pumpDecks(tester, decks);

    expect(
      _mountedRows(),
      inInclusiveRange(1, 40),
      reason: '500 generated rows must not mount at the initial 390x844 view.',
    );
    expect(_row(decks.first), findsOneWidget);
    expect(_row(decks.last), findsNothing);
    expect(api.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scroll reaches the final deck with its original selection ID', (
    tester,
  ) async {
    final decks = _decks();
    final selected = <int?>[];
    await _pumpDecks(tester, decks, onStudyDeck: selected.add);

    await tester.scrollUntilVisible(
      _row(decks.last),
      600,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 80,
    );
    await tester.pumpAndSettle();
    await tester.tap(_row(decks.last));
    expect(selected, [10499]);
    expect(find.text('500 due'), findsOneWidget);
    expect(_mountedRows(), lessThan(40));
    expect(_row(decks.first), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trimmed case-folded hierarchy search finds an unmounted row', (
    tester,
  ) async {
    final decks = _decks();
    final selected = <int?>[];
    final api = await _pumpDecks(tester, decks, onStudyDeck: selected.add);
    expect(_row(decks.last), findsNothing);

    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      '  INVENTED CORE::DECK 0499  ',
    );
    await tester.pumpAndSettle();
    expect(_mountedRows(), 1);
    expect(_row(decks.last), findsOneWidget);
    expect(find.byKey(const Key('recall_deck_hero')), findsNothing);
    await tester.tap(_row(decks.last));
    expect(selected, [10499]);
    expect(api.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional rows stay lazy and preserve search and saved expansion', (
    tester,
  ) async {
    final decks = _decks(optional: true);
    await _pumpDecks(tester, decks);
    expect(_mountedRows(), 0);

    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      'OPT-IN::DECK 0499',
    );
    await tester.pumpAndSettle();
    expect(_row(decks.last), findsOneWidget); // Search opens optional results.
    await tester.tap(find.text('Optional curricula'));
    await tester.pumpAndSettle();
    expect(_mountedRows(), 0);
    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      'OPT-IN::DECK 0498',
    );
    await tester.pumpAndSettle();
    expect(_mountedRows(), 0); // Same search-mode key retains a user collapse.
    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      'invented no matching deck',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching decks.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      'OPT-IN::DECK 0498',
    );
    await tester.pumpAndSettle();
    expect(_row(decks[498]), findsOneWidget); // A recreated search tile opens.
    await tester.tap(find.text('Optional curricula'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(_mountedRows(), 0); // The empty-query choice is still collapsed.

    await tester.tap(find.text('Optional curricula'));
    await tester.pumpAndSettle();
    expect(_mountedRows(), inInclusiveRange(1, 40));
    expect(_row(decks.last), findsNothing);
    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      'OPT-IN::DECK 0499',
    );
    await tester.pumpAndSettle();
    expect(_row(decks.last), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(_row(decks.first), findsOneWidget); // Restore the saved open choice.
    expect(_mountedRows(), lessThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long final deck and counts fit 320px at double text size', (
    tester,
  ) async {
    final decks = _decks(longLastName: true);
    final selected = <int?>[];
    await _pumpDecks(
      tester,
      decks,
      width: 320,
      textScale: 2,
      onStudyDeck: selected.add,
    );
    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      '0499',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(_row(decks.last));
    await tester.tap(_row(decks.last));
    expect(selected, [10499]);
    expect(find.text(_label(decks.last)), findsOneWidget);
    expect(find.text('500 due · 2 new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

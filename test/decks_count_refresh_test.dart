// Invented decks and in-process count responses only; no account or transport.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';

const _decks = [DeckRow(deckId: 41, name: 'Synthetic core')];
typedef _Counts = Map<int, ({int due, int neu})>;

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  ReviewState state = const ReviewState(loading: false, decks: _decks);

  void publish(ReviewState next) {
    state = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements RecallApi {
  final requests = <Completer<_Counts>>[];

  @override
  Future<_Counts> fetchDeckCounts() {
    final request = Completer<_Counts>();
    requests.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _mount(WidgetTester tester, _Controller controller, _Api api) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DecksScreen(
            controller: controller,
            api: api,
            onStudyDeck: (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('a replacement controller owns the count refresh listener', (
    tester,
  ) async {
    final first = _Controller();
    final second = _Controller();
    final api = _Api();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await _mount(tester, first, api);
    api.requests.single.complete({41: (due: 8, neu: 2)});
    await tester.pumpAndSettle();

    await _mount(tester, second, api);
    expect(api.requests, hasLength(2));
    api.requests.last.complete({41: (due: 3, neu: 0)});
    await tester.pumpAndSettle();
    first.publish(first.state.copyWith(decks: List<DeckRow>.of(_decks)));
    expect(api.requests, hasLength(2));
    second.publish(second.state.copyWith(decks: List<DeckRow>.of(_decks)));
    await tester.pump();
    expect(api.requests, hasLength(3));
    api.requests.last.complete({41: (due: 2, neu: 0)});
    await tester.pumpAndSettle();
    expect(find.text('Your core decks · 2 due · 0 new'), findsOneWidget);
  });

  testWidgets('outbox sync refreshes counts without replacing the deck list', (
    tester,
  ) async {
    final controller = _Controller();
    controller.state = controller.state.copyWith(pendingSync: 1);
    final api = _Api();
    addTearDown(controller.dispose);
    await _mount(tester, controller, api);
    api.requests.single.complete({41: (due: 8, neu: 2)});
    await tester.pumpAndSettle();

    controller.publish(controller.state.copyWith(pendingSync: 0));
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.requests.last.complete({41: (due: 7, neu: 2)});
    await tester.pumpAndSettle();
    expect(find.text('Your core decks · 7 due · 2 new'), findsOneWidget);
  });

  testWidgets('overlapping refreshes cannot publish an older response', (
    tester,
  ) async {
    final controller = _Controller();
    final api = _Api();
    addTearDown(controller.dispose);
    await _mount(tester, controller, api);
    controller.publish(
      controller.state.copyWith(decks: List<DeckRow>.of(_decks)),
    );
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.requests.last.complete({41: (due: 3, neu: 0)});
    await tester.pumpAndSettle();
    api.requests.first.complete({41: (due: 8, neu: 2)});
    await tester.pumpAndSettle();
    expect(find.text('Your core decks · 3 due · 0 new'), findsOneWidget);
    expect(find.text('8 due'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.publish(
      controller.state.copyWith(decks: List<DeckRow>.of(_decks)),
    );
    expect(api.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an automatic count refresh failure stays in the deck surface', (
    tester,
  ) async {
    final controller = _Controller();
    final api = _Api();
    addTearDown(controller.dispose);
    await _mount(tester, controller, api);
    api.requests.single.complete({41: (due: 8, neu: 2)});
    await tester.pumpAndSettle();
    controller.publish(
      controller.state.copyWith(decks: List<DeckRow>.of(_decks)),
    );
    await tester.pump();
    api.requests.last.completeError(StateError('Synthetic refresh failure'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load deck counts.'), findsOneWidget);
    expect(find.text('0 due'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a completed queue refresh reloads visible deck counts', (
    tester,
  ) async {
    final controller = _Controller();
    final api = _Api();
    addTearDown(controller.dispose);
    await _mount(tester, controller, api);
    api.requests.single.complete({41: (due: 8, neu: 2)});
    await tester.pumpAndSettle();
    expect(find.text('Your core decks · 8 due · 2 new'), findsOneWidget);

    // Metadata/answer ticks must not create additional queries.
    controller.publish(controller.state.copyWith(showBack: true));
    await tester.pump();
    expect(api.requests, hasLength(1));

    // A controller load publishes a new deck list, even when IDs match.
    controller.publish(
      controller.state.copyWith(
        decks: List<DeckRow>.of(_decks),
        globalDueCount: 3,
        globalDueUpdatedAt: DateTime.utc(2026, 10, 23, 15),
      ),
    );
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.requests.last.complete({41: (due: 3, neu: 0)});
    await tester.pumpAndSettle();
    expect(find.text('Your core decks · 3 due · 0 new'), findsOneWidget);
    expect(find.text('3 due'), findsOneWidget);
  });

  testWidgets('a successful empty count result shows zero for an empty deck', (
    tester,
  ) async {
    final controller = _Controller();
    final api = _Api();
    addTearDown(controller.dispose);
    await _mount(tester, controller, api);
    expect(find.text('0 due'), findsNothing);
    api.requests.single.complete({});
    await tester.pumpAndSettle();
    expect(find.text('0 due'), findsOneWidget);
    expect(find.text('Your core decks · 0 due · 0 new'), findsOneWidget);
  });

  testWidgets('a failed refresh removes previous authoritative count labels', (
    tester,
  ) async {
    final controller = _Controller();
    final api = _Api();
    addTearDown(controller.dispose);
    await _mount(tester, controller, api);
    api.requests.single.complete({41: (due: 8, neu: 2)});
    await tester.pumpAndSettle();

    final reload = tester
        .state<DecksScreenState>(find.byType(DecksScreen))
        .reload();
    final failure = expectLater(reload, throwsStateError);
    api.requests.last.completeError(StateError('Synthetic count failure'));
    await failure;
    await tester.pumpAndSettle();
    expect(find.text('Could not load deck counts.'), findsOneWidget);
    expect(find.text('8 due'), findsNothing);
    expect(find.textContaining('8 due ·'), findsNothing);
  });
}

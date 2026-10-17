import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 8, 5, 12);

const _bigDeck = 1;
const _newOnlyDeck = 2;
const _smallDeck = 3;

const _decks = [
  DeckRow(deckId: _bigDeck, name: 'Backlog'),
  DeckRow(deckId: _newOnlyDeck, name: 'Fresh'),
  DeckRow(deckId: _smallDeck, name: 'Small'),
];

/// A backlog above the offer threshold in one deck, a deck holding only new
/// cards, and a deck whose few due cards stay far below the threshold.
List<ReviewCard> _cards({int smallDue = 2}) => [
  for (var i = 0; i < 82; i++)
    testCard(
      id: 1000 + i,
      deckId: _bigDeck,
      state: 2,
      stability: (i + 1).toDouble(),
      difficulty: 5,
      due: _now.subtract(Duration(hours: i + 1)),
      lastReview: _now.subtract(Duration(days: i + 1)),
    ),
  for (var i = 0; i < 3; i++)
    testCard(id: 2000 + i, deckId: _newOnlyDeck, state: 0),
  for (var i = 0; i < smallDue; i++)
    testCard(
      id: 3000 + i,
      deckId: _smallDeck,
      state: 2,
      stability: 3,
      difficulty: 5,
      due: _now.subtract(const Duration(hours: 2)),
      lastReview: _now.subtract(const Duration(days: 3)),
    ),
];

ReviewController _controller(FakeRecallApi api, {LocalReviewStore? store}) {
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store ?? LocalReviewStore(),
    clock: () => _now,
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _rate(ReviewController controller, int times) async {
  for (var i = 0; i < times; i++) {
    controller.flip();
    await controller.rate(Rating.good);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('catch-up across deck switches', () {
    test('opening a new-only deck keeps today\'s active progress', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      await controller.startCatchUp();
      await _rate(controller, 3);
      expect(controller.state.catchUp.completedToday, 3);

      await controller.selectDeck(_newOnlyDeck);
      expect(controller.state.catchUp.dueCount, 0);
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.catchUp.completedToday, 3);
      expect(controller.state.catchUp.shouldOffer, isFalse);
      expect(controller.state.queue, hasLength(BacklogCatchUp.dailyCap - 3));
      final stored = await controller.store.loadCatchUpState();
      expect(stored.mode, CatchUpMode.active);
      expect(stored.completedToday, 3);
      expect(stored.dayKey, '2026-08-05');
    });

    test('opening a small deck keeps a dismissed offer dismissed', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      expect(controller.state.catchUp.shouldOffer, isTrue);
      await controller.showAll();

      await controller.selectDeck(_smallDeck);
      expect(controller.state.catchUp.shouldOffer, isFalse);
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isDismissed, isTrue);
      expect(controller.state.catchUp.shouldOffer, isFalse);
      expect(
        (await controller.store.loadCatchUpState()).mode,
        CatchUpMode.dismissed,
      );
    });

    test('opening a new-only deck keeps a dismissed offer dismissed', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      await controller.showAll();
      await controller.selectDeck(_newOnlyDeck);
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isDismissed, isTrue);
      expect(controller.state.catchUp.shouldOffer, isFalse);
    });

    test('rating in a small deck keeps the dismissal of the backlog', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      await controller.showAll();
      await controller.selectDeck(_smallDeck);
      await _rate(controller, 1);
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isDismissed, isTrue);
      expect(controller.state.catchUp.shouldOffer, isFalse);
    });

    test(
      'finishing a small deck counts towards, and keeps, today\'s cap',
      () async {
        final api = FakeRecallApi(_cards(), decks: _decks);
        final controller = _controller(api);

        await controller.load();
        await controller.startCatchUp();
        await _rate(controller, 2);

        await controller.selectDeck(_smallDeck);
        expect(controller.state.catchUp.isActive, isTrue);
        expect(controller.state.catchUp.completedToday, 2);
        await _rate(controller, 2);
        expect(controller.state.isDone, isTrue);

        await controller.selectDeck(null);

        expect(controller.state.catchUp.isActive, isTrue);
        expect(controller.state.catchUp.completedToday, 4);
        expect(controller.state.queue, hasLength(BacklogCatchUp.dailyCap - 4));
        expect((await controller.store.loadCatchUpState()).completedToday, 4);
      },
    );

    test('undo in a new-only deck does not wipe active progress', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      await controller.startCatchUp();
      await _rate(controller, 2);

      await controller.selectDeck(_newOnlyDeck);
      await _rate(controller, 1);
      expect(controller.canUndo, isTrue);
      await controller.undo();
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.catchUp.completedToday, 2);
    });

    test(
      'undo of the final card keeps the restored plan scoped to its stream',
      () async {
        final store = LocalReviewStore();
        await store.saveCatchUpState(
          const CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: '2026-08-05',
            completedToday: 19,
            deckStream: 'all',
          ),
        );
        final api = FakeRecallApi(_cards(smallDue: 0), decks: _decks)
          ..queue.removeWhere(
            (card) => card.deckId == _bigDeck && card.id > 1000,
          );
        final controller = _controller(api, store: store);

        await controller.load();
        expect(controller.state.catchUp.isActive, isTrue);
        api.beforeQueue = () async => throw StateError('offline');
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        await _rate(controller, 1);
        expect(controller.state.catchUp.isNone, isTrue);

        await controller.undo();
        expect(
          await store.loadCatchUpState(),
          const CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: '2026-08-05',
            completedToday: 19,
            deckStream: 'all',
          ),
        );

        api.beforeQueue = null;
        await controller.selectDeck(_newOnlyDeck);
        await controller.selectDeck(null);
        expect(controller.state.catchUp.isActive, isTrue);
        expect(controller.state.catchUp.completedToday, 19);
      },
    );

    test('a cold start on a new-only deck keeps the backlog plan', () async {
      final store = LocalReviewStore();
      final first = _controller(
        FakeRecallApi(_cards(), decks: _decks),
        store: store,
      );
      await first.load();
      await first.startCatchUp();
      await _rate(first, 5);
      await first.syncPending();

      final api = FakeRecallApi(_cards(), decks: _decks);
      final second = _controller(api, store: store);
      await second.load(deckId: _newOnlyDeck);
      await second.selectDeck(null);

      expect(second.state.catchUp.isActive, isTrue);
      expect(second.state.catchUp.completedToday, 5);
    });
  });

  group('all decks covers an episode owned by one deck', () {
    bool isDue(ReviewCard card) => card.deckId != _newOnlyDeck;

    test('an empty all-decks load ends a deck-owned plan', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load(deckId: _bigDeck);
      await controller.startCatchUp();
      await controller.selectDeck(null);
      expect(controller.state.catchUp.isActive, isTrue);

      api.queue.removeWhere(isDue);
      await controller.refresh();

      expect(controller.state.catchUp.isNone, isTrue);
      expect(await controller.store.loadCatchUpState(), CatchUpLocalState.none);
    });

    test('rating the last all-decks card ends a deck-owned plan', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load(deckId: _bigDeck);
      await controller.startCatchUp();
      api.queue.removeWhere((card) => isDue(card) && card.id != 1000);
      await controller.selectDeck(null);
      expect(controller.state.catchUp.isActive, isTrue);

      await _rate(controller, 1);

      expect(controller.state.catchUp.isNone, isTrue);
      expect(await controller.store.loadCatchUpState(), CatchUpLocalState.none);

      api.queue.addAll(_cards().where((card) => card.id > 1000 && isDue(card)));
      await controller.refresh();
      expect(controller.state.catchUp.isActive, isFalse);
      expect(controller.state.catchUp.shouldOffer, isTrue);
    });

    test(
      'undo after all decks ended it restores the plan to its deck',
      () async {
        final api = FakeRecallApi(_cards(), decks: _decks);
        final controller = _controller(api);

        await controller.load(deckId: _bigDeck);
        await controller.startCatchUp();
        api.queue.removeWhere((card) => isDue(card) && card.id != 1000);
        await controller.selectDeck(null);
        // Offline keeps the rating in the outbox so that Undo can remove it.
        api.beforeQueue = () async => throw StateError('offline');
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        expect(controller.state.catchUp.isActive, isTrue);
        await _rate(controller, 1);
        expect(controller.state.catchUp.isNone, isTrue);
        expect(
          await controller.store.loadCatchUpState(),
          CatchUpLocalState.none,
        );

        await controller.undo();

        expect(
          await controller.store.loadCatchUpState(),
          const CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: '2026-08-05',
            deckStream: 'deck:$_bigDeck',
          ),
        );
      },
    );

    test('a small all-decks backlog expires a deck-owned dismissal', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load(deckId: _bigDeck);
      await controller.showAll();
      api.queue.removeWhere(
        (card) => card.deckId == _bigDeck && card.id >= 1010,
      );
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isNone, isTrue);
      expect(
        (await controller.store.loadCatchUpState()).mode,
        CatchUpMode.none,
      );

      api.queue.addAll(
        _cards().where((card) => card.id >= 1010 && isDue(card)),
      );
      await controller.refresh();
      expect(controller.state.catchUp.shouldOffer, isTrue);
    });

    test(
      'rating all decks below the threshold expires a deck-owned dismissal',
      () async {
        final api = FakeRecallApi(_cards(), decks: _decks);
        final controller = _controller(api);

        await controller.load(deckId: _bigDeck);
        await controller.showAll();
        await controller.selectDeck(null);
        expect(controller.state.catchUp.isDismissed, isTrue);
        final aboveThreshold =
            controller.state.catchUp.dueCount -
            controller.state.catchUp.threshold;

        await _rate(controller, aboveThreshold);

        expect(controller.state.catchUp.isNone, isTrue);
        expect(
          (await controller.store.loadCatchUpState()).mode,
          CatchUpMode.none,
        );

        api.queue.addAll([
          for (var i = 0; i < 10; i++)
            testCard(
              id: 4000 + i,
              deckId: _smallDeck,
              state: 2,
              stability: 3,
              difficulty: 5,
              due: _now.subtract(const Duration(hours: 1)),
              lastReview: _now.subtract(const Duration(days: 3)),
            ),
        ]);
        await controller.refresh();
        expect(controller.state.catchUp.shouldOffer, isTrue);
      },
    );

    test('an empty deck still keeps an all-decks plan', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      await controller.startCatchUp();
      api.queue.removeWhere((card) => card.deckId == _smallDeck);
      await controller.selectDeck(_smallDeck);
      expect(controller.state.catchUp.dueCount, 0);

      final stored = await controller.store.loadCatchUpState();
      expect(stored.mode, CatchUpMode.active);
      expect(stored.deckStream, 'all');
    });
  });

  group('catch-up within a single deck is unchanged', () {
    test('an emptied selected deck still clears its own episode', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load(deckId: _bigDeck);
      await controller.startCatchUp();
      expect(controller.state.catchUp.isActive, isTrue);

      api.queue.removeWhere((card) => card.deckId == _bigDeck);
      await controller.refresh();

      expect(controller.state.catchUp.isNone, isTrue);
      expect(await controller.store.loadCatchUpState(), CatchUpLocalState.none);
    });

    test('a dismissal still expires once its own backlog is small', () async {
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = _controller(api);

      await controller.load();
      await controller.showAll();
      api.queue.removeWhere(
        (card) => card.deckId == _bigDeck && card.id >= 1010,
      );
      await controller.refresh();

      expect(controller.state.catchUp.isNone, isTrue);
      expect(
        (await controller.store.loadCatchUpState()).mode,
        CatchUpMode.none,
      );

      api.queue.addAll(_cards().where((card) => card.id >= 1010));
      await controller.refresh();
      expect(controller.state.catchUp.shouldOffer, isTrue);
    });

    test('a new day still restarts the cap but keeps the plan', () async {
      var now = _now;
      final store = LocalReviewStore();
      final api = FakeRecallApi(_cards(), decks: _decks);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => now,
      );
      addTearDown(controller.dispose);

      await controller.load();
      await controller.startCatchUp();
      await _rate(controller, 3);

      now = _now.add(const Duration(days: 1));
      await controller.selectDeck(_newOnlyDeck);
      await controller.selectDeck(null);

      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.catchUp.completedToday, 0);
      expect((await store.loadCatchUpState()).dayKey, '2026-08-06');
    });
  });
}

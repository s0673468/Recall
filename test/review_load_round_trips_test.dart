// Round-trip counting for ReviewController.load. The fake server answers
// every request that is open at the same moment as one round, so a serial
// dependency between reads shows up as an extra round. Every row is invented.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 16, 12);

const _offlineError =
    'Recall is offline and no saved study queue is available.';

/// Holds the reads on load's critical path until the test answers a round.
class _RoundApi extends FakeRecallApi {
  _RoundApi(super.queue, {super.decks});

  final List<Completer<void>> _open = [];
  final List<String> openKinds = [];
  bool failDecks = false;
  bool failQueue = false;

  /// Fails only queue reads that exclude a hidden card (the refetch here).
  bool failRefetch = false;

  /// The hidden set each fetchQueue call excluded, in call order.
  final List<Set<int>> queueExclusions = [];

  Future<void> _wait(String kind) {
    final gate = Completer<void>();
    _open.add(gate);
    openKinds.add(kind);
    return gate.future;
  }

  /// Answers every open request at once; returns how many there were.
  int answerRound() {
    final open = [..._open];
    _open.clear();
    openKinds.clear();
    for (final gate in open) {
      gate.complete();
    }
    return open.length;
  }

  @override
  Future<List<DeckRow>> fetchDecks() async {
    await _wait('decks');
    if (failDecks) throw StateError('invented deck read failure');
    return super.fetchDecks();
  }

  @override
  Future<Set<int>> fetchHiddenCardIds() async {
    await _wait('hidden');
    return super.fetchHiddenCardIds();
  }

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    queueExclusions.add(excludeCardIds);
    await _wait('queue');
    if (failQueue || (failRefetch && excludeCardIds.isNotEmpty)) {
      throw StateError('invented queue read failure');
    }
    return super.fetchQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      newLimit: newLimit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
  }
}

/// Drives [load] to completion one server round at a time.
Future<int> _countRounds(_RoundApi api, Future<void> load) async {
  var done = false;
  Object? error;
  unawaited(
    load.then(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  var rounds = 0;
  while (true) {
    await pumpEventQueue(times: 200);
    if (done) break;
    if (api.answerRound() == 0) fail('load stalled with no open request');
    rounds++;
    if (rounds > 20) fail('load did not settle');
  }
  if (error != null) throw error!;
  return rounds;
}

ReviewCard _due(int id, int deckId) => testCard(
  id: id,
  deckId: deckId,
  state: 2,
  reps: 3,
  due: _now.subtract(const Duration(hours: 1)),
  lastReview: _now.subtract(const Duration(days: 5)),
);

_RoundApi _api() => _RoundApi(
  [_due(1, 1), _due(2, 1), _due(3, 2)],
  decks: const [
    DeckRow(deckId: 1, name: 'Invented A'),
    DeckRow(deckId: 2, name: 'Invented B'),
  ],
)..user = testUser('invented-round-owner');

ReviewController _controller(_RoundApi api) {
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: LocalReviewStore(),
    clock: () => _now,
  );
  addTearDown(controller.dispose);
  return controller;
}

void _hideOnServer(_RoundApi api, int cardId) => api.flagged.add({
  'client_id': 'invented-flag-$cardId',
  'card_id': cardId,
  'reason': 'dislike',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('load round trips', () {
    test('a selected deck fetches its queue alongside the deck read', () async {
      final api = _api();
      final controller = _controller(api);

      final rounds = await _countRounds(api, controller.load(deckId: 1));

      // Decks, hidden flags and the queue all travel in the first round.
      expect(rounds, 1);
      expect(api.lastIncludedDeckIds, isNull);
      expect(controller.state.queue.map((c) => c.id), [1, 2]);
      expect(controller.state.decks, hasLength(2));
      expect(controller.state.error, isNull);
    });

    test(
      'all decks still waits for the deck read to scope the queue',
      () async {
        final api = _api();
        final controller = _controller(api);

        final rounds = await _countRounds(api, controller.load());

        expect(rounds, 2);
        expect(api.lastIncludedDeckIds, {1, 2});
        expect(controller.state.queue.map((c) => c.id), [1, 2, 3]);
      },
    );

    test('a changed hidden set refetches without waiting for the fan-out '
        '(selected deck)', () async {
      final api = _api();
      _hideOnServer(api, 2);
      final controller = _controller(api);

      final rounds = await _countRounds(api, controller.load(deckId: 1));

      // Round 1: decks, hidden, stale queue. Round 2: refetch.
      expect(rounds, 2);
      expect(api.queueExclusions, [
        <int>{},
        {2},
      ]);
      expect(controller.state.queue.map((c) => c.id), [1]);
    });

    test('a changed hidden set refetches alongside the first queue read '
        '(all decks)', () async {
      final api = _api();
      _hideOnServer(api, 3);
      final controller = _controller(api);

      final rounds = await _countRounds(api, controller.load());

      // Round 1: decks and hidden. Round 2: both queue reads together.
      expect(rounds, 2);
      expect(api.queueExclusions, [
        <int>{},
        {3},
      ]);
      expect(api.lastIncludedDeckIds, {1, 2});
      expect(controller.state.queue.map((c) => c.id), [1, 2]);
    });

    test('an unchanged hidden set never refetches', () async {
      final api = _api();
      final controller = _controller(api);

      await _countRounds(api, controller.load(deckId: 2));

      expect(api.queueExclusions, [<int>{}]);
      expect(controller.state.queue.map((c) => c.id), [3]);
    });
  });

  group('load failures surface as before', () {
    for (final deckId in [null, 1]) {
      final label = deckId == null ? 'all decks' : 'selected deck';

      test('failing deck read ($label)', () async {
        final api = _api()..failDecks = true;
        final controller = _controller(api);

        await _countRounds(api, controller.load(deckId: deckId));

        expect(controller.state.loading, isFalse);
        expect(controller.state.error, _offlineError);
        expect(controller.state.queue, isEmpty);
        expect(controller.state.decks, isEmpty);
      });

      test('failing queue read ($label)', () async {
        final api = _api()..failQueue = true;
        final controller = _controller(api);

        await _countRounds(api, controller.load(deckId: deckId));

        expect(controller.state.loading, isFalse);
        expect(controller.state.error, _offlineError);
        expect(controller.state.queue, isEmpty);
      });

      test('failing early refetch ($label)', () async {
        final api = _api()..failRefetch = true;
        _hideOnServer(api, 2);
        final controller = _controller(api);

        await _countRounds(api, controller.load(deckId: deckId));

        expect(api.queueExclusions, [
          <int>{},
          {2},
        ]);
        expect(controller.state.error, _offlineError);
        expect(controller.state.queue, isEmpty);
      });
    }

    test('a superseded load never applies its early refetch', () async {
      final api = _api();
      _hideOnServer(api, 2);
      final controller = _controller(api);

      final stale = controller.load(deckId: 1);
      await pumpEventQueue(times: 200);
      // Round 1 resolves the hidden set; the stale load's refetch is now open.
      api.answerRound();
      await pumpEventQueue(times: 200);
      expect(api.openKinds, contains('queue'));

      final fresh = controller.load(deckId: 2);
      await _countRounds(api, Future.wait([stale, fresh]));

      expect(controller.state.deckFilter, 2);
      expect(controller.state.queue.map((c) => c.id), [3]);
      expect(controller.state.error, isNull);
      expect(controller.state.loading, isFalse);
    });
  });
}

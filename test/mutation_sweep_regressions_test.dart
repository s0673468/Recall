// Mutation survivors exercised with invented scheduling state and in-memory
// preferences only. No card content, accounts, or production services are used.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating, defaultParameters;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/review_replay.dart';

class _ReplayGateway implements ReviewReplayGateway {
  _ReplayGateway(this.state, {this.updated = 1});

  final CardSyncState state;
  final int updated;
  int reads = 0;
  final expectedVersions = <int?>[];
  final patches = <Map<String, dynamic>>[];

  @override
  Future<CardSyncState?> readCardState(int cardId) async {
    expect(cardId, 901);
    reads++;
    return state;
  }

  @override
  Future<int> updateCardWhereReps(
    int cardId, {
    required int? expectedReps,
    required Map<String, dynamic> values,
  }) async {
    expect(cardId, 901);
    expectedVersions.add(expectedReps);
    patches.add(Map.from(values));
    return updated;
  }
}

ReviewCard _card({
  int state = 2,
  double? stability = 10,
  DateTime? due,
  DateTime? lastReview,
}) => ReviewCard(
  id: 901,
  guid: 'invented-mutation-sweep',
  deckId: 1,
  front: '',
  back: '',
  hasLatex: false,
  stability: stability,
  difficulty: stability == null ? null : 5,
  due: due,
  state: state,
  reps: 7,
  lapses: 4,
  lastReview: lastReview,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 17, 12);

  test('Again during relearning increments existing lapses exactly once', () {
    final outcome = FsrsEngine().review(
      _card(
        state: 3,
        due: now,
        lastReview: now.subtract(const Duration(minutes: 10)),
      ),
      Rating.again,
      now: now,
    );
    expect(outcome.lapses, 5); // S03: relearning is also review-like.
    expect(outcome.reps, 8);
    expect(outcome.state, 3);
    expect(outcome.due, now.add(const Duration(minutes: 10)));
  });

  test('missing learning timestamps restart at step zero', () {
    // S06: neither missing timestamp can prove completion of the final step.
    for (final timestamps in [
      (due: null, lastReview: now.subtract(const Duration(minutes: 10))),
      (due: now, lastReview: null),
      (due: null, lastReview: null),
    ]) {
      final outcome = FsrsEngine().review(
        _card(
          state: 1,
          stability: 1,
          due: timestamps.due,
          lastReview: timestamps.lastReview,
        ),
        Rating.good,
        now: now,
      );
      expect(outcome.state, 1);
      expect(outcome.due, now.add(const Duration(minutes: 10)));
    }
  });

  test('Hard keeps a persisted relearning card in its fifteen minute step', () {
    final outcome = FsrsEngine().review(
      _card(
        state: 3,
        due: now,
        lastReview: now.subtract(const Duration(minutes: 10)),
      ),
      Rating.hard,
      now: now,
    );
    expect(outcome.state, 3); // S07: reconstruct relearning, not review.
    expect(outcome.lapses, 4);
    expect(outcome.due, now.add(const Duration(minutes: 15)));
  });

  test(
    'new state ignores stale stability and previous learning timestamps',
    () {
      final engine = FsrsEngine();
      for (final rating in Rating.values) {
        final fresh = engine.review(
          _card(state: 0, stability: null),
          rating,
          now: now,
        );
        final stale = engine.review(
          _card(
            state: 0,
            due: now,
            lastReview: now.subtract(const Duration(minutes: 10)),
          ),
          rating,
          now: now,
        );
        expect(stale.state, fresh.state); // S08: new overrides stale columns.
        expect(stale.due, fresh.due);
        expect(stale.stability, fresh.stability);
        expect(stale.difficulty, fresh.difficulty);
      }
    },
  );

  test(
    'changing retention preserves custom parameters and changes scheduling',
    () {
      // A synthetic vector derived from package defaults, never fitted user data.
      final parameters = [...defaultParameters];
      parameters[0] *= 0.95;
      final engine = FsrsEngine(parameters: parameters);
      final card = _card(
        due: now,
        lastReview: now.subtract(const Duration(days: 10)),
      );
      final oldDue = engine.review(card, Rating.good, now: now).due;
      engine.setDesiredRetention(0.8);
      expect(
        engine.parameters,
        parameters,
      ); // S09: do not reset fitted weights.
      expect(engine.desiredRetention, 0.8);
      final updated = engine.review(card, Rating.good, now: now);
      expect(updated.due.isAfter(oldDue), isTrue);
      expect(
        updated.due,
        FsrsEngine(
          parameters: parameters,
          desiredRetention: 0.8,
        ).review(card, Rating.good, now: now).due,
      );
    },
  );

  test(
    'retrievability uses the requested instant and leaves the card intact',
    () {
      final engine = FsrsEngine();
      final card = _card(due: now, lastReview: now);
      final before = card.toJson();
      expect(engine.retrievability(card, now: now), 1); // S10: no elapsed days.
      expect(
        engine.retrievability(card, now: now.add(const Duration(days: 10))),
        closeTo(0.9, 1e-12), // FSRS stability is the time to 90% recall.
      );
      expect(card.toJson(), before);
    },
  );

  test('unequal nested list lengths make delivery identity ambiguous', () {
    // O05: an extra list element changes the immutable payload, in either order.
    for (final values in [
      [
        [1],
        [1, 2],
      ],
      [
        [1, 2],
        [1],
      ],
    ]) {
      expect(
        LocalReviewStore.uniqueDeliveryIds([
          for (final value in values)
            {
              'client_id': 'invented-list-event',
              'nested': {'values': value},
            },
        ]),
        isEmpty,
      );
    }
  });

  test('undo requires an explicitly false delivery marker', () async {
    // O02: absent, null and unrecognized old markers cannot prove no send.
    final rows = <Map<String, dynamic>>[
      {'client_id': 'invented-absent'},
      {'client_id': 'invented-null', 'delivery_attempted': null},
      {'client_id': 'invented-old', 'delivery_attempted': 'unknown'},
      {'client_id': 'invented-sent', 'delivery_attempted': true},
      {'client_id': 'invented-fresh', 'delivery_attempted': false},
    ];
    SharedPreferences.setMockInitialValues({
      'recall_outbox_v1': jsonEncode(rows),
    });
    final store = LocalReviewStore();
    for (final row in rows.take(4)) {
      expect(await store.removeEntry(row['client_id'] as String), (
        removed: false,
        remaining: 5,
      ));
      expect(await store.outbox(), rows);
    }
    expect(await store.removeEntry('invented-fresh'), (
      removed: true,
      remaining: 4,
    ));
    expect(await store.outbox(), rows.take(4).toList());
  });

  test('whitespace owner fails before any migration claim or copy', () async {
    SharedPreferences.setMockInitialValues({
      'recall_outbox_v1': '[{"client_id":"invented-legacy-event"}]',
    });
    final writer = await SharedPreferences.getInstance();
    final before = {for (final key in writer.getKeys()) key: writer.get(key)};
    final store = LocalReviewStore();
    await expectLater(
      store.activateOwner(' \t\n '),
      throwsArgumentError,
    ); // M04
    expect(store.activeOwnerScope, isNull);
    expect(store.ownerAware, isFalse);
    await writer.reload();
    expect({for (final key in writer.getKeys()) key: writer.get(key)}, before);
  });

  test(
    'first replay preserves SQL null in its compare-and-swap predicate',
    () async {
      final gateway = _ReplayGateway(
        const CardSyncState(reps: null, lapses: null, lastReview: null),
      );
      await applyMergedReview(gateway, {
        'card_id': 901,
        'last_review': now.toIso8601String(),
        'rating': 3,
        'state': 2,
      });
      expect(gateway.reads, 1);
      expect(gateway.expectedVersions, [
        null,
      ]); // R06: SQL NULL differs from zero.
      expect(gateway.patches.single['reps'], 1);
      expect(gateway.patches.single['lapses'], 0);
      expect(gateway.patches.single['last_review'], now.toIso8601String());
    },
  );

  test(
    'replay contention performs exactly the allowed number of attempts',
    () async {
      for (final limit in [1, reviewReplayMaxAttempts]) {
        final gateway = _ReplayGateway(
          const CardSyncState(reps: 7, lapses: 4, lastReview: null),
          updated: 0,
        );
        await expectLater(
          applyMergedReview(gateway, {
            'card_id': 901,
            'last_review': now.toIso8601String(),
            'rating': 3,
            'state': 2,
          }, maxAttempts: limit),
          throwsA(
            isA<ReviewReplayConflict>()
                .having((error) => error.cardId, 'cardId', 901)
                .having((error) => error.attempts, 'attempts', limit),
          ),
        );
        expect(
          gateway.reads,
          limit,
        ); // R07: never perform an extra write attempt.
        expect(gateway.expectedVersions, List<int>.filled(limit, 7));
        expect(gateway.patches, hasLength(limit));
      }
    },
  );
}

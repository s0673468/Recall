import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 22, 12);

class _CountingCard extends ReviewCard {
  _CountingCard(int id, int state)
    : super(
        id: id,
        guid: 'synthetic-$id',
        deckId: 1,
        front: 'Synthetic front',
        back: 'Synthetic back',
        hasLatex: false,
        stability: 5,
        difficulty: 5,
        due: null,
        state: state,
        reps: 0,
        lapses: 0,
        lastReview: null,
      );

  int reads = 0;

  @override
  bool get isNew {
    reads++;
    return super.isNew;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [2000, 20000]) {
    test('queue counters visit $size cards once across actions and Undo', () {
      final cards = List.generate(size, (i) => _CountingCard(i, i % 4));
      final initial = const ReviewState().copyWith(queue: cards);
      for (final index in [0, 1, 99, size ~/ 2, size, size + 1, 99, 0]) {
        final state = initial.copyWith(index: index, pendingSync: 4);
        final remaining = index >= size ? 0 : size - index;
        final newCount = index >= size
            ? 0
            : (size - 1) ~/ 4 - (index + 3) ~/ 4 + 1;
        expect(state.newRemaining, newCount);
        expect(state.dueRemaining, remaining - newCount);
        expect(identical(state.queue, initial.queue), isTrue);
      }
      expect(cards.fold<int>(0, (sum, card) => sum + card.reads), size);
    });

    test('bounded ranking matches full stable sort for $size cards', () {
      final cards = [
        for (var i = 0; i < size; i++)
          testCard(
            id: i,
            state: i % 10 == 0 ? 0 : 2,
            // Repeated values deliberately create ties at the cap boundary.
            stability: 1 + (i % 7).toDouble(),
            difficulty: 5,
            due: _now.subtract(const Duration(days: 1)),
            lastReview: _now.subtract(Duration(days: i % 9 + 1)),
          ),
      ]..shuffle(Random(42));
      final engine = FsrsEngine();
      final expected =
          [
            for (var i = 0; i < cards.length; i++)
              if (!cards[i].isNew)
                (
                  card: cards[i],
                  index: i,
                  r: engine.retrievability(cards[i], now: _now),
                ),
          ]..sort((a, b) {
            final order = a.r.compareTo(b.r);
            return order == 0 ? a.index.compareTo(b.index) : order;
          });
      final original = cards.toList();
      for (final completed in [-2, 0, 1, 19, 20, 25]) {
        final actual = BacklogCatchUp.takeDueForToday(
          cards.where((_) => true),
          engine,
          now: _now,
          completedToday: completed,
        );
        expect(
          actual,
          expected.take(max(0, 20 - completed)).map((r) => r.card),
        );
      }
      expect(cards, original);
    });
  }

  test('counter index owns its queue and replaces stale prefix counts', () {
    final source = [testCard(id: 1), testCard(id: 2, state: 2)];
    final state = const ReviewState().copyWith(queue: source);
    expect(state.newRemaining, 1);
    source.clear();
    expect(state.queue, hasLength(2));
    expect(() => state.queue.clear(), throwsUnsupportedError);
    final next = state.copyWith(queue: [testCard(id: 3, state: 3)]);
    expect(next.newRemaining, 0);
    expect(next.dueRemaining, 1);
    expect(state.newRemaining, 1);
    expect(() => state.copyWith(index: -1).dueRemaining, throwsRangeError);
    expect(const ReviewState().copyWith(queue: []).dueRemaining, 0);
  });

  test(
    'ranking traverses a lazy source once and keeps equal ranks in order',
    () {
      var traversals = 0;
      Iterable<ReviewCard> source() sync* {
        expect(++traversals, 1);
        for (var i = 0; i < 30; i++) {
          yield testCard(id: i, state: i == 5 ? 0 : 2);
        }
      }

      expect(
        BacklogCatchUp.orderDue(
          source(),
          FsrsEngine(),
          now: _now,
        ).map((c) => c.id),
        [
          for (var i = 0; i < 30; i++)
            if (i != 5) i,
        ],
      );
      traversals = 0;
      expect(
        BacklogCatchUp.takeDueForToday(
          source(),
          FsrsEngine(),
          now: _now,
          completedToday: 1,
        ).map((c) => c.id),
        [
          for (var i = 0; i < 20; i++)
            if (i != 5) i,
        ],
      );
      Iterable<ReviewCard> mustNotRead() sync* {
        fail('An exhausted daily cap must not rank the backlog');
      }

      expect(
        BacklogCatchUp.takeDueForToday(
          mustNotRead(),
          FsrsEngine(),
          now: _now,
          completedToday: 20,
        ),
        isEmpty,
      );
      expect(
        BacklogCatchUp.takeDueForToday(
          [],
          FsrsEngine(),
          now: _now,
          completedToday: 0,
        ),
        isEmpty,
      );
    },
  );

  test(
    'catch-up controller keeps validation priority and the new-card gate',
    () async {
      SharedPreferences.setMockInitialValues({});
      final validation = testCard(
        id: 9000,
        state: 0,
        contentRevalidationPending: true,
      );
      final due = [
        for (var i = 0; i < 2000; i++)
          testCard(
            id: i,
            state: 2,
            stability: 5,
            due: _now.subtract(const Duration(days: 1)),
          ),
      ];
      final cards = [testCard(id: 9001), ...due, validation];
      final controller = ReviewController(
        api: FakeRecallApi(cards),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => _now,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.startCatchUp();
      expect(controller.state.queue.map((c) => c.id), [
        validation.id,
        ...due.take(20).map((c) => c.id),
      ]);
      expect(controller.state.dueRemaining, 20);
      expect(controller.state.newRemaining, 1);
      await controller.showAll();
      expect(
        controller.state.queue.map((c) => c.id).toSet(),
        cards.map((c) => c.id).toSet(),
      );
    },
  );
}

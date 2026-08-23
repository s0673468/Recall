import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Scheduler, Card, State;

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

ReviewCard _card(
  int id, {
  double stability = 10,
  int daysSinceReview = 10,
  int state = 2,
}) {
  final now = DateTime.utc(2026, 8, 5, 12);
  return ReviewCard(
    id: id,
    guid: 'g$id',
    deckId: 1,
    front: 'front$id',
    back: 'back$id',
    hasLatex: false,
    stability: stability,
    difficulty: 5,
    due: now.subtract(const Duration(hours: 1)),
    state: state,
    reps: 5,
    lapses: 0,
    lastReview: now.subtract(Duration(days: daysSinceReview)),
  );
}

void main() {
  group('BacklogCatchUp', () {
    test('uses the floor and twice the recent daily average', () {
      expect(BacklogCatchUp.thresholdForAverage(0), 80);
      expect(BacklogCatchUp.thresholdForAverage(10), 80);
      expect(BacklogCatchUp.thresholdForAverage(40), 80);
      expect(BacklogCatchUp.thresholdForAverage(41), 82);
      expect(
        BacklogCatchUp.isEligible(dueCount: 80, recentDailyAverage: 40),
        isFalse,
      );
      expect(
        BacklogCatchUp.isEligible(dueCount: 81, recentDailyAverage: 40),
        isTrue,
      );
    });

    test(
      'recent average includes zero-activity days for a stable threshold',
      () {
        final now = DateTime(2026, 8, 5, 12);
        final reviews = [
          for (var i = 0; i < 14; i++)
            for (var j = 0; j < (i == 0 ? 14 : 0); j++)
              ReviewLogEntry(
                cardId: j,
                at: now.subtract(Duration(days: i, minutes: j)),
                rating: 3,
              ),
        ];

        expect(
          BacklogCatchUp.recentDailyAverage(reviews, now: now),
          closeTo(1, 1e-9),
        );
      },
    );

    test('orders due cards by the package retrievability function', () {
      final now = DateTime.utc(2026, 8, 5, 12);
      final engine = FsrsEngine();
      final cards = [
        _card(1, stability: 100, daysSinceReview: 1),
        _card(2, stability: 2, daysSinceReview: 30),
      ];

      final ordered = BacklogCatchUp.orderDue(cards, engine, now: now);
      final scheduler = Scheduler(
        parameters: engine.parameters,
        desiredRetention: engine.desiredRetention,
        enableFuzzing: false,
      );
      final packageCard = Card(
        cardId: 2,
        state: State.review,
        stability: 2,
        difficulty: 5,
        due: now.subtract(const Duration(hours: 1)),
        lastReview: now.subtract(const Duration(days: 30)),
      );

      expect(ordered.map((card) => card.id), [2, 1]);
      expect(
        engine.retrievability(cards[1], now: now),
        scheduler.getCardRetrievability(packageCard, currentDateTime: now),
      );
    });

    test('daily cap slices and resumes without changing the source queue', () {
      final cards = [for (var i = 0; i < 25; i++) _card(i + 1)];
      final originalIds = cards.map((card) => card.id).toList();

      final first = BacklogCatchUp.takeForToday(cards, completedToday: 0);
      final resumed = BacklogCatchUp.takeForToday(
        cards,
        completedToday: 5,
      );

      expect(first, hasLength(BacklogCatchUp.dailyCap));
      expect(resumed, hasLength(BacklogCatchUp.dailyCap - 5));
      expect(cards.map((card) => card.id), originalIds);
      expect(BacklogCatchUp.estimatedDays(25), 2);
      expect(BacklogCatchUp.estimatedDays(0), 0);
    });

    test('estimated days accounts for capacity already used today', () {
      expect(BacklogCatchUp.estimatedDays(80, completedToday: 2), 5);
      expect(BacklogCatchUp.estimatedDays(20, completedToday: 19), 2);
      expect(
        const CatchUpView(
          mode: CatchUpMode.active,
          dueCount: 80,
          completedToday: 2,
        ).estimatedDays,
        5,
      );
    });

    test('local mode has explicit opt-in, opt-out, and cleared states', () {
      const none = CatchUpLocalState.none;
      expect(none.mode, CatchUpMode.none);
      expect(none.copyWith(mode: CatchUpMode.active).mode, CatchUpMode.active);
      expect(
        none.copyWith(mode: CatchUpMode.dismissed).mode,
        CatchUpMode.dismissed,
      );
    });
  });
}

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

    // 2026 transitions: Berlin Mar 29 / Oct 25, New York Mar 8 / Nov 1. The
    // fake zones map wall-clock dates to the instant of that local midnight,
    // so these run identically whatever the test process's TZ is.
    DateTime berlinMidnight(int year, int month, int day) {
      final date = DateTime.utc(year, month, day);
      final summer =
          !date.isBefore(DateTime.utc(2026, 3, 30)) &&
          !date.isAfter(DateTime.utc(2026, 10, 25));
      return date.subtract(Duration(hours: summer ? 2 : 1));
    }

    DateTime newYorkMidnight(int year, int month, int day) {
      final date = DateTime.utc(year, month, day);
      final summer =
          !date.isBefore(DateTime.utc(2026, 3, 9)) &&
          !date.isAfter(DateTime.utc(2026, 11, 1));
      return date.add(Duration(hours: summer ? 4 : 5));
    }

    for (final zone in [
      (name: 'Europe/Berlin', midnight: berlinMidnight),
      (name: 'America/New_York', midnight: newYorkMidnight),
    ]) {
      for (final today in [
        // Day after each change, and the last day the old cutoff misread.
        if (zone.name == 'Europe/Berlin') ...[
          DateTime.utc(2026, 3, 30),
          DateTime.utc(2026, 4, 11),
          DateTime.utc(2026, 10, 26),
          DateTime.utc(2026, 11, 7),
        ] else ...[
          DateTime.utc(2026, 3, 9),
          DateTime.utc(2026, 3, 21),
          DateTime.utc(2026, 11, 2),
          DateTime.utc(2026, 11, 14),
        ],
      ]) {
        test(
          'recent window is 14 calendar days in ${zone.name} on '
          '${today.toIso8601String().substring(0, 10)}',
          () {
            // One review per wall-clock day from 15 days back through today.
            // UTC values carry the zone's wall-clock fields for the seam.
            final reviews = [
              for (var i = 0; i <= BacklogCatchUp.recentDays; i++)
                ReviewLogEntry(
                  at: DateTime.utc(today.year, today.month, today.day - i, 9),
                  rating: 3,
                ),
            ];

            expect(
              BacklogCatchUp.recentDailyAverage(
                reviews,
                now: today.add(const Duration(hours: 12)),
                localDate: zone.midnight,
              ),
              closeTo(1, 1e-9),
            );
          },
        );
      }
    }

    test('recent window uses process-local calendar days by default', () {
      // Meaningful under TZ=Europe/Berlin or TZ=America/New_York; holds in
      // every zone because the window is counted in local calendar days.
      for (final today in [
        DateTime(2026, 3, 9),
        DateTime(2026, 3, 30),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
      ]) {
        final reviews = [
          for (var i = 0; i <= BacklogCatchUp.recentDays; i++)
            ReviewLogEntry(
              at: DateTime(today.year, today.month, today.day - i),
              rating: 3,
            ),
        ];
        expect(
          BacklogCatchUp.recentDailyAverage(
            reviews,
            now: DateTime(today.year, today.month, today.day, 12),
          ),
          closeTo(1, 1e-9),
          reason: 'today=$today',
        );
      }
    });

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

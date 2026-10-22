import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('midnight moves heatmap, streak and overdue forecast together', () {
    final before = DateTime(2026, 10, 22, 23, 59, 59);
    final after = DateTime(2026, 10, 23);
    final log = [ReviewLogEntry(at: before, rating: 3)];

    expect(StatsService.tileStats(log, today: after).streak, 1);
    log.add(ReviewLogEntry(at: after, rating: 1));
    expect(StatsService.tileStats(log, today: after).streak, 2);
    final heatmap = StatsService.buildHeatmap(log, today: after);
    expect(
      heatmap.singleWhere((day) => day.date == DateTime(2026, 10, 22)).count,
      1,
    );
    expect(heatmap.singleWhere((day) => day.date == after).count, 1);
    expect(
      StatsService.buildForecast([before, after], today: after).first.count,
      2,
    );
  });

  test('offset timestamps regroup into the current device calendar', () {
    // The same instant recorded on opposite sides of the date line. Repeat
    // this suite under different TZ values to exercise the receiving device.
    final east = DateTime.parse('2026-10-23T00:30:00+14:00').toLocal();
    final west = DateTime.parse('2026-10-22T00:30:00-10:00').toLocal();
    expect(east.isAtSameMomentAs(west), isTrue);
    final log = [
      ReviewLogEntry(at: east, rating: 3),
      ReviewLogEntry(at: west, rating: 1),
    ];
    final day = DateTime(east.year, east.month, east.day);
    expect(
      StatsService.buildHeatmap(
        log,
        today: east,
      ).singleWhere((cell) => cell.date == day).count,
      2,
    );
    expect(StatsService.tileStats(log, today: east).recall, '50%');
    expect(StatsService.computeRetention(log, now: east).overallRate, 0.5);
    expect(
      StatsService.buildForecast([east, west], today: east).first.count,
      2,
    );
  });

  test('reset learning history breaks the old mature interval', () {
    final now = DateTime(2026, 10, 22, 12);
    final summary = StatsService.computeRetention([
      ReviewLogEntry(
        cardId: 1,
        at: DateTime(2026, 7, 1),
        rating: 1,
        stateAfter: 3,
      ),
      ReviewLogEntry(
        cardId: 1,
        at: DateTime(2026, 10, 21, 12),
        rating: 3,
        stateAfter: 1,
      ),
      ReviewLogEntry(cardId: 1, at: now, rating: 3, stateAfter: 2),
    ], now: now);
    expect(summary.total, 1);
    expect(summary.youngTotal, 1);
    expect(summary.matureTotal, 0);
  });

  test('deleted card histories retain their original review evidence', () {
    final now = DateTime(2026, 10, 22, 12);
    // Hard-deleted cards can have no surviving card id. Their append-only
    // history still contributes, without linking unrelated null-id rows.
    final log = [
      ReviewLogEntry(at: DateTime(2026, 10, 1), rating: 1, stateAfter: 3),
      ReviewLogEntry(at: now, rating: 3, stateAfter: 2),
    ];
    final summary = StatsService.computeRetention(log, now: now);
    expect(summary.total, 2);
    expect(summary.passed, 1);
    expect(summary.hasCohorts, isFalse);
    expect(StatsService.tileStats(log, today: now).reviews, 2);
  });

  test('a long unordered history preserves counts and predecessor cohorts', () {
    final now = DateTime(2026, 10, 22, 12);
    final log = [
      for (var id = 0; id < 10000; id++) ...[
        ReviewLogEntry(
          cardId: id,
          at: DateTime(2026, 1, 1),
          rating: 3,
          stateAfter: 2,
        ),
        ReviewLogEntry(cardId: id, at: now, rating: id.isEven ? 3 : 1),
      ],
    ]..shuffle(Random(22));
    final summary = StatsService.computeRetention(log, now: now);
    expect(summary.total, 10000);
    expect(summary.passed, 5000);
    expect(summary.matureTotal, 10000);
    expect(summary.maturePassed, 5000);
    final tiles = StatsService.tileStats(log, today: now);
    expect(tiles.reviews, 10000);
    expect(tiles.recall, '50%');
    expect(
      StatsService.buildHeatmap(
        log,
        today: now,
      ).fold<int>(0, (sum, day) => sum + day.count),
      10000,
    );
  });

  for (final now in [
    DateTime(2026, 3, 7, 23, 30),
    DateTime(2026, 10, 31, 23, 30),
  ]) {
    test('forecast matches FSRS due cutoffs from $now across DST', () {
      final engine = FsrsEngine();
      final dueDates = [
        DateTime(now.year, now.month, now.day - 1), // overdue
        for (final state in [0, 1, 2, 3])
          for (final stability in [0.1, 5.0, 30.0])
            for (final rating in Rating.values)
              engine
                  .review(
                    testCard(
                      front: '',
                      back: '',
                      state: state,
                      stability: stability,
                      difficulty: 5,
                      due: now.toUtc(),
                      lastReview: now
                          .subtract(const Duration(days: 10))
                          .toUtc(),
                    ),
                    rating,
                    now: now,
                  )
                  .due
                  .toLocal(),
      ];
      final forecast = StatsService.buildForecast(dueDates, today: now);
      var cumulative = 0;
      for (var i = 0; i < forecast.length; i++) {
        cumulative += forecast[i].count;
        final nextMidnight = DateTime(now.year, now.month, now.day + i + 1);
        expect(
          cumulative,
          dueDates.where((due) => due.isBefore(nextMidnight)).length,
          reason: 'all scheduled cards due before $nextMidnight',
        );
      }
    });
  }

  test('empty automatic decks produce an empty forecast and history', () async {
    final service = StatsService(FakeRecallApi([], decks: []));
    expect(await service.loadAutomaticDueDates(), isEmpty);
    final forecast = StatsService.buildForecast(
      [],
      today: DateTime(2026, 10, 22),
    );
    expect(forecast, hasLength(14));
    expect(forecast.every((day) => day.count == 0), isTrue);
    final log = await service.loadReviewLog();
    expect(
      StatsService.computeRetention(log, now: DateTime(2026, 10, 22)).isEmpty,
      isTrue,
    );
  });

  test(
    'an undone offline review never reaches statistics after sync',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = _ServerHistoryApi();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      api.beforeQueue = () async => throw StateError('synthetic offline');
      await controller.refresh();
      expect(controller.state.offline, isTrue);
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.canUndo, isTrue);
      await controller.undo();
      await controller.syncPending();

      final log = await StatsService(api).loadReviewLog(refresh: true);
      final now = DateTime.now();
      expect(api.server.reviewLog, isEmpty);
      expect(StatsService.tileStats(log, today: now).reviews, 0);
      expect(StatsService.computeRetention(log, now: now).isEmpty, isTrue);
      expect(
        StatsService.buildHeatmap(log, today: now).every((d) => d.count == 0),
        isTrue,
      );
    },
  );
}

class _ServerHistoryApi extends FakeRecallApi {
  _ServerHistoryApi() : super([testCard(front: '', back: '')]);

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async => [
    for (final row in server.reviewLog)
      ReviewLogEntry(
        cardId: row['card_id'] as int,
        at: DateTime.parse(row['rating_at'] as String).toLocal(),
        rating: row['rating'] as int,
      ),
  ];
}

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

// Run with TZ=America/New_York as well as the default zone to cover both
// daylight-saving transitions. Calendar-day expectations apply in either zone.
void main() {
  for (final transition in [
    (name: 'spring', start: DateTime(2026, 3, 7)),
    (name: 'autumn', start: DateTime(2026, 10, 31)),
  ]) {
    final start = transition.start;
    DateTime day(int offset) =>
        DateTime(start.year, start.month, start.day + offset);

    test('heatmap keeps local dates across ${transition.name} transition', () {
      final grid = StatsService.buildHeatmap(
        [ReviewLogEntry(at: day(1), rating: 3)],
        today: day(2),
        weeks: 2,
      );
      // Both examples end on a Monday. Two Sunday-started columns cover the
      // previous Sunday through the upcoming Saturday, with no shifted hours.
      expect(grid.map((cell) => cell.date), [
        for (var i = -6; i <= 7; i++) day(i),
      ]);
      expect(grid.singleWhere((cell) => cell.date == day(1)).count, 1);
    });

    test('forecast keeps local dates across ${transition.name} transition', () {
      final forecast = StatsService.buildForecast(
        [day(-1), day(0), day(1), day(2), day(3)],
        today: start,
        days: 3,
      );
      expect(forecast.map((cell) => cell.date), [day(0), day(1), day(2)]);
      expect(forecast.map((cell) => cell.count), [2, 1, 1]);
    });

    test('streak spans ${transition.name} calendar days', () {
      final reviews = [
        for (var i = 0; i <= 2; i++) ReviewLogEntry(at: day(i), rating: 3),
      ];
      expect(StatsService.tileStats(reviews, today: day(2)).streak, 3);
      // An unfinished current day must retain the streak through yesterday.
      expect(StatsService.tileStats(reviews, today: day(3)).streak, 3);
    });
  }

  test('retention window begins at local midnight after autumn transition', () {
    final retention = StatsService.computeRetention(
      [ReviewLogEntry(at: DateTime(2026, 11, 1, 0, 30), rating: 3)],
      now: DateTime(2026, 11, 2),
      windowDays: 1,
    );
    expect(retention.total, 1);
  });

  test(
    'concept window includes its full first local day after autumn shift',
    () {
      final retention = StatsService.computeNodeRetention(
        reviewLog: [
          ReviewLogEntry(guid: 'note', at: DateTime(2026, 11, 1), rating: 3),
        ],
        noteTags: {'note': 'node::concept'},
        conceptNodes: [
          const ConceptNodeInfo(
            nodeId: 'concept',
            title: 'Concept',
            module: 'M0',
          ),
        ],
        now: DateTime(2026, 11, 2),
        window: 2,
        minReviews: 1,
      );
      expect(retention.coveredNodeCount, 1);
      expect(retention.ranked.single.reviews, 1);
    },
  );
}

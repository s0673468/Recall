import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

ReviewLogEntry _entry(
  DateTime at,
  int rating, {
  DateTime? dueAfter,
}) => ReviewLogEntry(at: at, rating: rating, dueAfter: dueAfter);

ReviewLogEntry _review(String? guid, DateTime at, int rating) =>
    ReviewLogEntry(guid: guid, at: at, rating: rating);

ConceptNodeInfo _node(String id, {String? title, String module = 'M00'}) =>
    ConceptNodeInfo(nodeId: id, title: title ?? id, module: module);

void main() {
  group('buildHeatmap', () {
    test('groups a UTC timestamp into its correct local day', () {
      // The service converts to local before bucketing; verify the review lands
      // on its local calendar day, not the UTC one.
      final utc = DateTime.utc(2026, 7, 7, 2, 30);
      final local = utc.toLocal();
      final grid = StatsService.buildHeatmap(
        [_entry(local, 3)],
        today: local.add(const Duration(days: 1)),
      );
      final cell = grid.firstWhere(
        (d) => d.date == StatsService.dayOnly(local),
      );
      expect(cell.count, 1);
    });

    test('buckets reviews at a day boundary onto distinct local days', () {
      final today = DateTime(2026, 7, 8, 12);
      final grid = StatsService.buildHeatmap([
        _entry(DateTime(2026, 7, 7, 23, 45), 3),
        _entry(DateTime(2026, 7, 8, 0, 15), 3),
      ], today: today);
      int countFor(DateTime d) =>
          grid.firstWhere((c) => c.date == d).count;
      expect(countFor(DateTime(2026, 7, 7)), 1);
      expect(countFor(DateTime(2026, 7, 8)), 1);
    });

    test('ignores reviews before the window and covers 26 weeks', () {
      final today = DateTime(2026, 7, 8, 12);
      final grid = StatsService.buildHeatmap([
        _entry(today.subtract(const Duration(days: 400)), 3),
      ], today: today);
      expect(grid.length, 26 * 7);
      expect(grid.fold<int>(0, (a, d) => a + d.count), 0);
    });
  });

  group('heatmapLevel', () {
    test('0 count → level 0, nonzero → 1..4 scaled to the max', () {
      expect(StatsService.heatmapLevel(0, 10), 0);
      expect(StatsService.heatmapLevel(10, 10), 4);
      expect(StatsService.heatmapLevel(1, 10), inInclusiveRange(1, 4));
      // Any positive count with a max of 1 is the top bucket.
      expect(StatsService.heatmapLevel(1, 1), 4);
    });
  });

  group('buildForecast', () {
    test('rolls overdue and today into day 0, drops beyond horizon', () {
      final today = DateTime(2026, 7, 7, 9);
      final forecast = StatsService.buildForecast([
        DateTime(2026, 7, 1), // overdue
        DateTime(2026, 7, 7, 20), // today (later than "now")
        DateTime(2026, 7, 10), // +3
        DateTime(2026, 7, 25), // beyond 14-day horizon
      ], today: today);
      expect(forecast.length, 14);
      expect(forecast[0].count, 2); // overdue + today
      expect(forecast[0].index, 0);
      expect(forecast[3].count, 1);
      expect(forecast.every((d) => d.index >= 0), isTrue);
      expect(forecast.fold<int>(0, (a, d) => a + d.count), 3); // 25th dropped
    });
  });

  group('computeRetention', () {
    test('pass rate counts not-Again (rating >= 2)', () {
      final now = DateTime(2026, 7, 7, 12);
      final r = StatsService.computeRetention([
        _entry(now.subtract(const Duration(days: 1)), 1),
        _entry(now.subtract(const Duration(days: 1)), 2),
        _entry(now.subtract(const Duration(days: 1)), 3),
        _entry(now.subtract(const Duration(days: 1)), 4),
      ], now: now);
      expect(r.total, 4);
      expect(r.passed, 3);
      expect(r.overallRate, 0.75);
    });

    test('splits young vs mature by the 21-day interval', () {
      final now = DateTime(2026, 7, 7, 12);
      final at = now.subtract(const Duration(days: 1));
      final r = StatsService.computeRetention([
        _entry(at, 3, dueAfter: at.add(const Duration(days: 5))), // young pass
        _entry(at, 1, dueAfter: at.add(const Duration(days: 3))), // young fail
        _entry(at, 3, dueAfter: at.add(const Duration(days: 40))), // mature pass
      ], now: now);
      expect(r.hasCohorts, isTrue);
      expect(r.youngTotal, 2);
      expect(r.youngPassed, 1);
      expect(r.matureTotal, 1);
      expect(r.maturePassed, 1);
      expect(r.matureRate, 1.0);
    });

    test('excludes reviews outside the window', () {
      final now = DateTime(2026, 7, 7, 12);
      final r = StatsService.computeRetention([
        _entry(now.subtract(const Duration(days: 40)), 3), // outside 30d
        _entry(now.subtract(const Duration(days: 2)), 3),
      ], now: now, windowDays: 30);
      expect(r.total, 1);
    });

    test('zero reviews → empty, no NaN', () {
      final r = StatsService.computeRetention([], now: DateTime(2026, 7, 7));
      expect(r.isEmpty, isTrue);
      expect(r.overallRate, isNull);
      expect(r.hasCohorts, isFalse);
    });

    test('no due_after data → overall only, no cohorts', () {
      final now = DateTime(2026, 7, 7, 12);
      final r = StatsService.computeRetention([
        _entry(now.subtract(const Duration(days: 1)), 3),
      ], now: now);
      expect(r.total, 1);
      expect(r.hasCohorts, isFalse);
    });
  });

  group('tileStats', () {
    test('recall % and streak from the review log', () {
      final today = DateTime(2026, 7, 7, 12);
      final t = StatsService.tileStats([
        _entry(today, 3),
        _entry(today.subtract(const Duration(days: 1)), 1),
      ], today: today);
      expect(t.reviews, 2);
      expect(t.recall, '50%');
      expect(t.streak, 2); // today + yesterday
    });

    test('empty log → dash recall, zero streak', () {
      final t = StatsService.tileStats([], today: DateTime(2026, 7, 7));
      expect(t.recall, '—');
      expect(t.reviews, 0);
      expect(t.streak, 0);
    });
  });

  group('nodeTags', () {
    test('parses node:: tokens, dedupes, drops node::none and non-node tags', () {
      expect(
        StatsService.nodeTags('leech node::m00-a marked node::m01-b node::m00-a'),
        ['m00-a', 'm01-b'],
      );
      expect(StatsService.nodeTags('node::none node::m02-c'), ['m02-c']);
      expect(StatsService.nodeTags('node:: node::none'), isEmpty);
      expect(StatsService.nodeTags(null), isEmpty);
      expect(StatsService.nodeTags(''), isEmpty);
    });
  });

  group('computeNodeRetention', () {
    final now = DateTime(2026, 7, 20, 12);
    DateTime daysAgo(int n) => now.subtract(Duration(days: n));

    test("attributes a note's reviews to every node:: tag it carries", () {
      // g1 teaches two nodes; 4 reviews, 1 Again → both nodes see 4 rev / 1 again.
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          _review('g1', daysAgo(1), 1),
          _review('g1', daysAgo(1), 3),
          _review('g1', daysAgo(2), 3),
          _review('g1', daysAgo(2), 4),
        ],
        noteTags: {'g1': 'node::m00-a node::m01-b'},
        conceptNodes: [_node('m00-a'), _node('m01-b')],
        now: now,
      );
      expect(result.ranked.length, 2);
      expect(result.coveredNodeCount, 2);
      for (final n in result.ranked) {
        expect(n.reviews, 4);
        expect(n.againCount, 1);
        expect(n.againRate, closeTo(0.25, 1e-9));
      }
    });

    test('excludes the node::none sentinel entirely', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          for (var i = 0; i < 4; i++) _review('g1', daysAgo(1), 3),
        ],
        noteTags: {'g1': 'node::none'},
        conceptNodes: const [],
        now: now,
      );
      expect(result.ranked, isEmpty);
      expect(result.coveredNodeCount, 0);
      expect(result.notEnoughData, 0);
    });

    test('ranks only nodes at/above the floor; the rest are notEnoughData', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          // ranked: 4 reviews.
          for (var i = 0; i < 4; i++) _review('g1', daysAgo(1), 3),
          // below floor: 3 reviews.
          for (var i = 0; i < 3; i++) _review('g2', daysAgo(1), 3),
        ],
        noteTags: {'g1': 'node::ranked', 'g2': 'node::thin'},
        conceptNodes: [_node('ranked'), _node('thin')],
        now: now,
        minReviews: 4,
      );
      expect(result.ranked.map((n) => n.nodeId), ['ranked']);
      expect(result.notEnoughData, 1);
      expect(result.coveredNodeCount, 2); // both had reviews this window
    });

    test('orders weakest (highest Again-rate) first', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          // weak: 2/4 again = 50%.
          _review('g1', daysAgo(1), 1),
          _review('g1', daysAgo(1), 1),
          _review('g1', daysAgo(1), 3),
          _review('g1', daysAgo(1), 3),
          // strong: 1/4 again = 25%.
          _review('g2', daysAgo(1), 1),
          _review('g2', daysAgo(1), 3),
          _review('g2', daysAgo(1), 3),
          _review('g2', daysAgo(1), 3),
        ],
        noteTags: {'g1': 'node::weak', 'g2': 'node::strong'},
        conceptNodes: [_node('weak'), _node('strong')],
        now: now,
      );
      expect(result.ranked.map((n) => n.nodeId), ['weak', 'strong']);
    });

    test('excludes reviews outside the window and with a null guid', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          _review('g1', daysAgo(20), 3), // outside 14d window
          _review(null, daysAgo(1), 1), // null guid → attributes to nothing
          for (var i = 0; i < 4; i++) _review('g1', daysAgo(1), 3),
        ],
        noteTags: {'g1': 'node::a'},
        conceptNodes: [_node('a')],
        now: now,
      );
      expect(result.ranked.single.reviews, 4);
    });

    test('a guid missing from the tags map contributes nothing', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          for (var i = 0; i < 4; i++) _review('untagged', daysAgo(1), 1),
        ],
        noteTags: const {}, // no tag mapping for this guid
        conceptNodes: const [],
        now: now,
      );
      expect(result.ranked, isEmpty);
      expect(result.coveredNodeCount, 0);
    });

    test('leaves title/module null when no concept_nodes row resolves the id', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: [
          for (var i = 0; i < 4; i++) _review('g1', daysAgo(1), 1),
        ],
        noteTags: {'g1': 'node::m99-orphan'},
        conceptNodes: const [], // table empty / id absent
        now: now,
      );
      final node = result.ranked.single;
      expect(node.nodeId, 'm99-orphan');
      expect(node.title, isNull);
      expect(node.module, isNull);
      expect(node.againRate, 1.0);
    });

    test('empty inputs → empty result, no throw', () {
      final result = StatsService.computeNodeRetention(
        reviewLog: const [],
        noteTags: const {},
        conceptNodes: const [],
        now: now,
      );
      expect(result.ranked, isEmpty);
      expect(result.notEnoughData, 0);
      expect(result.coveredNodeCount, 0);
    });
  });
}

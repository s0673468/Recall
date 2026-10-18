import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import '../tool/scheduler/protocol.dart';
import 'support/recall_test_harness.dart';

final _dates = [
  (2026, 1, 1),
  (2026, 1, 31),
  (2026, 2, 28),
  (2026, 3, 1),
  (2026, 12, 31),
  (2027, 2, 28),
  (2028, 2, 29),
];

// All rows and scheduling histories in this suite are invented. HTTP never
// leaves MockClient; an empty key avoids introducing even a dummy credential.
Map<String, dynamic> _row(int id, DateTime? due) => {
  'id': id,
  'guid': 'synthetic-$id',
  'state': due == null ? 0 : 1,
  'due': due?.toUtc().toIso8601String(),
  'notes': {'front': 'synthetic front', 'back': 'synthetic back', 'deck_id': 1},
};

class _Transport {
  final List<Map<String, dynamic>> cards;
  final List<Uri> requests = [];
  void Function()? onRequest;

  _Transport(this.cards);

  late final client = SupabaseClient(
    'https://date-boundary.invalid',
    '',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      requests.add(request.url);
      onRequest?.call();
      final q = request.url.queryParameters;
      final rows = request.url.path.endsWith('/cards') && q['or'] == null
          ? cards.where((row) {
              if (q['state'] == 'eq.0') return row['state'] == 0;
              if (q['state'] != 'neq.0' || row['due'] == null) return false;
              return !DateTime.parse(
                row['due'] as String,
              ).isAfter(DateTime.parse(q['due']!.substring(4)));
            }).toList()
          : <Map<String, dynamic>>[];
      return http.Response(
        jsonEncode(rows),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  Iterable<Uri> get dueRequests => requests.where(
    (uri) =>
        uri.path.endsWith('/cards') && uri.queryParameters['state'] == 'neq.0',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (year, month, day) in _dates) {
    final now = DateTime(year, month, day, 0, 30);
    final label = '$year-$month-$day 00:30 local';

    test('queue cutoff and introduction window use fixed $label', () async {
      final transport = _Transport([
        _row(1, now.subtract(const Duration(microseconds: 1))),
        _row(2, now),
        _row(3, now.add(const Duration(microseconds: 1))),
      ]);
      addTearDown(transport.client.dispose);
      final api = RecallApi(transport.client, localNow: () => now);
      expect((await api.fetchQueue()).map((card) => card.id), [1, 2]);
      expect(
        transport.dueRequests.first.queryParameters['due'],
        'lte.${now.toUtc().toIso8601String()}',
      );
      final log = transport.requests.firstWhere(
        (uri) => uri.path.endsWith('/review_log'),
      );
      expect(log.queryParametersAll['rating_at'], [
        'gte.${DateTime(year, month, day).toUtc().toIso8601String()}',
        'lt.${DateTime(year, month, day + 1).toUtc().toIso8601String()}',
      ]);
    });

    test('ahead horizon uses fixed $label', () async {
      final horizon = now.toUtc().add(const Duration(hours: 24));
      final transport = _Transport([
        _row(1, horizon),
        _row(2, horizon.add(const Duration(microseconds: 1))),
      ]);
      addTearDown(transport.client.dispose);
      final api = RecallApi(transport.client, localNow: () => now);
      expect((await api.fetchAheadQueue()).map((card) => card.id), [1]);
    });

    test('FSRS and web protocol preserve elapsed intervals at $label', () {
      final engine = FsrsEngine();
      final card = testCard();
      final preview = engine.preview(card, now: now);
      for (final rating in Rating.values) {
        final outcome = engine.review(card, rating, now: now);
        expect(outcome.reviewedAt, now.toUtc());
        expect(outcome.due, preview[rating]);
        expect(outcome.due.isUtc, isTrue);
        expect(outcome.due.isAfter(now), isTrue);
        final wire =
            scheduleRequest({
                  'operation': 'review',
                  'card': _row(1, null),
                  'now': now.toIso8601String(),
                  'rating': rating.value,
                })
                as Map<String, dynamic>;
        expect(wire['due'], outcome.due.toIso8601String());
      }
      expect(
        preview[Rating.again]!.difference(now),
        const Duration(minutes: 1),
      );
      expect(
        preview[Rating.good]!.difference(now),
        const Duration(minutes: 10),
      );
    });

    test('elapsed scheduling is date-independent in every state at $label', () {
      final reference = DateTime.utc(2026, 6, 15, 12);
      final engine = FsrsEngine();
      for (final state in [1, 2, 3]) {
        ReviewCard cardAt(DateTime at) => testCard(
          state: state,
          stability: 5,
          difficulty: 5,
          due: at.toUtc(),
          lastReview: at.toUtc().subtract(
            state == 2 ? const Duration(days: 5) : const Duration(minutes: 10),
          ),
        );
        for (final rating in Rating.values) {
          final result = engine.review(cardAt(now), rating, now: now);
          final expected = engine.review(
            cardAt(reference),
            rating,
            now: reference,
          );
          expect(
            result.due.difference(now),
            expected.due.difference(reference),
          );
          expect(result.state, expected.state);
          expect(result.stability, expected.stability);
          expect(result.difficulty, expected.difficulty);
        }
      }
    });

    test('forecast follows calendar dates at $label', () {
      final forecast = StatsService.buildForecast(
        [
          DateTime(year, month, day - 1, 23, 59),
          now,
          DateTime(year, month, day + 1, 0, 1),
          DateTime(year, month, day + 2),
        ],
        today: now,
        days: 3,
      );
      expect(forecast.map((bucket) => bucket.count), [2, 1, 1]);
      expect(forecast.map((bucket) => bucket.date), [
        for (var offset = 0; offset < 3; offset++)
          DateTime(year, month, day + offset),
      ]);
    });

    test('23:59 review is due at 00:01 across $year-$month-$day', () async {
      final reviewedAt = DateTime(year, month, day, 23, 59);
      final checkedAt = DateTime(year, month, day + 1, 0, 1);
      final engine = FsrsEngine();
      final again = engine.review(testCard(), Rating.again, now: reviewedAt);
      final good = engine.review(testCard(), Rating.good, now: reviewedAt);
      expect(again.due, DateTime(year, month, day + 1).toUtc());
      final transport = _Transport([_row(1, again.due), _row(2, good.due)]);
      addTearDown(transport.client.dispose);
      final api = RecallApi(transport.client, localNow: () => checkedAt);
      expect((await api.fetchQueue()).map((card) => card.id), [1]);
    });
  }

  test(
    'one queue load keeps its start day when transport crosses midnight',
    () async {
      final startedAt = DateTime(2026, 1, 31, 23, 59);
      var now = startedAt;
      var reads = 0;
      final transport = _Transport([
        for (var id = 1; id <= 10; id++) _row(id, null),
      ]);
      addTearDown(transport.client.dispose);
      transport.onRequest = () => now = DateTime(2026, 2, 1, 0, 1);
      final api = RecallApi(
        transport.client,
        localNow: () {
          reads++;
          return now;
        },
      );
      final queue = await api.fetchQueue(order: NewOrder.random);
      expect(reads, 1);
      expect(
        queue.map((card) => card.id),
        seededShuffle([
          for (var id = 1; id <= 10; id++) id,
        ], newOrderDaySeed(startedAt, null)),
      );
      final log = transport.requests.firstWhere(
        (uri) => uri.path.endsWith('/review_log'),
      );
      expect(log.queryParametersAll['rating_at'], [
        'gte.${DateTime(2026, 1, 31).toUtc().toIso8601String()}',
        'lt.${DateTime(2026, 2, 1).toUtc().toIso8601String()}',
      ]);
    },
  );

  test('ahead shuffle keeps its start day across midnight', () async {
    final startedAt = DateTime(2026, 12, 31, 23, 59);
    var now = startedAt;
    var reads = 0;
    final transport = _Transport([
      for (var id = 1; id <= 10; id++) _row(id, null),
    ]);
    addTearDown(transport.client.dispose);
    transport.onRequest = () => now = DateTime(2027, 1, 1, 0, 1);
    final queue = await RecallApi(
      transport.client,
      localNow: () {
        reads++;
        return now;
      },
    ).fetchAheadQueue(order: NewOrder.random);
    expect(reads, 1);
    expect(
      queue.map((card) => card.id),
      seededShuffle([
        for (var id = 1; id <= 10; id++) id,
      ], newOrderDaySeed(startedAt, null)),
    );
  });

  test('review history cutoff uses the shared clock', () async {
    final now = DateTime(2028, 3, 1, 0, 30);
    final transport = _Transport([]);
    addTearDown(transport.client.dispose);
    await RecallApi(
      transport.client,
      localNow: () => now,
    ).fetchReviewLog(days: 2);
    expect(
      transport.requests.single.queryParameters['rating_at'],
      'gte.${now.toUtc().subtract(const Duration(days: 2)).toIso8601String()}',
    );
  });

  test('scheduler reads its clock once and explicit now overrides it', () {
    var reads = 0;
    final now = DateTime(2028, 2, 29, 23, 59);
    final engine = FsrsEngine(
      clock: () {
        reads++;
        return now;
      },
    );
    for (final card in [
      testCard(),
      testCard(state: 1, stability: 1.5, difficulty: 5),
      testCard(
        state: 2,
        stability: 10,
        difficulty: 5,
        lastReview: now.toUtc().subtract(const Duration(days: 2)),
      ),
      testCard(
        state: 3,
        stability: 10,
        difficulty: 5,
        lastReview: now.toUtc().subtract(const Duration(minutes: 10)),
      ),
    ]) {
      final preview = engine.preview(card);
      expect(reads, 1);
      for (final rating in Rating.values) {
        final result = engine.review(card, rating, now: now);
        expect(result.due, preview[rating]);
        expect(reads, 1);
      }
      expect(engine.review(card, Rating.good).due, preview[Rating.good]);
      expect(reads, 2);
      expect(
        engine.retrievability(card),
        engine.retrievability(card, now: now),
      );
      expect(reads, 3);
      reads = 0;
    }
  });

  test('offset timestamp in web protocol denotes the same instant as UTC', () {
    Map<String, dynamic> request(String now) => {
      'operation': 'preview',
      'card': _row(1, null),
      'now': now,
    };
    expect(
      scheduleRequest(request('2026-03-01T00:30:00-03:00')),
      scheduleRequest(request('2026-03-01T03:30:00Z')),
    );
  });

  test('controller recent activity uses the scheduling clock', () async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime(2026, 1, 1, 0, 1);
    final reviewedAt = DateTime(2025, 12, 31, 23, 59);
    final api = _ActivityApi([ReviewLogEntry(at: reviewedAt, rating: 3)]);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(clock: () => now),
      store: LocalReviewStore(),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.reviewActivityKnown, isTrue);
    expect(controller.state.lastReviewedAt, reviewedAt);
  });
}

class _ActivityApi extends FakeRecallApi {
  final List<ReviewLogEntry> reviews;
  _ActivityApi(this.reviews) : super([]);

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async =>
      reviews;
}

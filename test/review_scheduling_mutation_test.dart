// Invented scheduling state only. No content fixtures or live transport.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

import 'support/recall_test_harness.dart';

Map<String, dynamic> _row(int id, DateTime? due) => {
  'id': id,
  'guid': 'synthetic-schedule-$id',
  'state': due == null ? 0 : 2,
  'due': due?.toIso8601String(),
  'notes': {'front': '', 'back': '', 'deck_id': 1},
};

// Interpret the actual wire operators, including strict vs inclusive cutoffs.
// Merely returning a preselected list would hide boundary mutations.
bool _matchesTime(DateTime at, String filter) {
  final dot = filter.indexOf('.');
  final bound = DateTime.parse(filter.substring(dot + 1));
  return switch (filter.substring(0, dot)) {
    'lt' => at.isBefore(bound),
    'lte' => !at.isAfter(bound),
    'gt' => at.isAfter(bound),
    'gte' => !at.isBefore(bound),
    _ => throw StateError('Unexpected time filter: $filter'),
  };
}

class _QueueTransport {
  final List<Map<String, dynamic>> cards;
  final List<Map<String, dynamic>> logs;
  final requests = <Uri>[];

  _QueueTransport(this.cards, {this.logs = const []});

  late final client = SupabaseClient(
    'https://scheduling.invalid',
    '',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      requests.add(request.url);
      final q = request.url.queryParameters;
      var rows = <Map<String, dynamic>>[];
      if (request.url.path.endsWith('/cards') && q['state'] != null) {
        rows = cards.where((row) {
          if (q['state'] == 'eq.0') return row['state'] == 0;
          return row['state'] != 0 &&
              row['due'] != null &&
              _matchesTime(DateTime.parse(row['due'] as String), q['due']!);
        }).toList();
        if (q['state'] == 'neq.0') {
          rows.sort(
            (a, b) => (a['due'] as String).compareTo(b['due'] as String),
          );
        }
        // These fixtures fit in one due page; the continuation proves exhaustion.
        if (q['or'] != null) rows = [];
      } else if (request.url.path.endsWith('/review_log')) {
        rows = logs.where((row) {
          final at = DateTime.parse(row['rating_at'] as String);
          return (request.url.queryParametersAll['rating_at'] ?? []).every(
                (filter) => _matchesTime(at, filter),
              ) &&
              (q['id'] == null || row['id'] > int.parse(q['id']!.substring(3)));
        }).toList();
      }
      final limit = int.tryParse(q['limit'] ?? '') ?? rows.length;
      return http.Response(
        jsonEncode(rows.take(limit).toList()),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 18, 12);

  test(
    'ordinary queue includes exactly due now and excludes one microsecond ahead',
    () async {
      final transport = _QueueTransport([
        _row(1, now.subtract(const Duration(microseconds: 1))),
        _row(2, now),
        _row(3, now.add(const Duration(microseconds: 1))),
      ]);
      addTearDown(transport.client.dispose);
      final queue = await RecallApi(
        transport.client,
        localNow: () => now,
      ).fetchQueue(newLimit: 0);
      expect(queue.map((card) => card.id), [1, 2]);
      final due = transport.requests.firstWhere(
        (uri) => uri.queryParameters['state'] == 'neq.0',
      );
      expect(due.queryParameters['due'], 'lte.${now.toIso8601String()}');
    },
  );

  test(
    'custom ahead horizon includes its boundary and tops up only free slots',
    () async {
      final horizon = now.add(const Duration(minutes: 90));
      final transport = _QueueTransport([
        _row(1, now.subtract(const Duration(days: 1))),
        _row(2, horizon),
        _row(3, horizon.add(const Duration(microseconds: 1))),
        _row(4, null),
        _row(5, null),
      ]);
      addTearDown(transport.client.dispose);
      final queue = await RecallApi(
        transport.client,
        localNow: () => now,
      ).fetchAheadQueue(horizon: const Duration(minutes: 90), limit: 3);
      expect(queue.map((card) => card.id), [1, 2, 4]);
      expect(
        transport.requests.first.queryParameters['due'],
        'lte.${horizon.toIso8601String()}',
      );
      expect(transport.requests.last.queryParameters['limit'], '1');
    },
  );

  test(
    'daily budget reconstructs distinct first reviews in a half-open day',
    () async {
      final start = DateTime.utc(2026, 10, 18);
      final end = start.add(const Duration(days: 1));
      Map<String, dynamic> log(int id, int cardId, DateTime at) => {
        'id': id,
        'card_id': cardId,
        'rating_at': at.toIso8601String(),
      };
      final transport = _QueueTransport(
        [for (var id = 1; id <= 3; id++) _row(id, null)],
        logs: [
          log(1, 101, start.subtract(const Duration(microseconds: 1))),
          log(2, 101, now), // A repeat of a previously introduced card.
          log(3, 102, start),
          log(4, 102, start), // Two reviews consume just one introduction.
          log(5, 103, end), // Tomorrow never consumes today's budget.
        ],
      );
      addTearDown(transport.client.dispose);
      final queue = await RecallApi(
        transport.client,
        localNow: () => now,
        // Keep the day boundaries aligned with the UTC fixtures on every host.
        localMidnight: DateTime.utc,
      ).fetchQueue(newLimit: 3);
      expect(queue.map((card) => card.id), [1, 2]);
    },
  );

  test(
    'FSRS reconstructs nondefault difficulty and elapsed review history',
    () {
      final engine = FsrsEngine();
      final scheduler = fsrs.Scheduler(enableFuzzing: false);
      final last = now.subtract(const Duration(days: 13));
      final card = testCard(
        state: 2,
        stability: 17,
        difficulty: 8.2,
        due: now.subtract(const Duration(days: 2)),
        lastReview: last,
        reps: 7,
      );
      for (final rating in fsrs.Rating.values) {
        final expected = scheduler
            .reviewCard(
              fsrs.Card(
                cardId: card.id,
                state: fsrs.State.review,
                stability: 17,
                difficulty: 8.2,
                due: card.due,
                lastReview: last,
              ),
              rating,
              reviewDateTime: now,
            )
            .card;
        final actual = engine.review(card, rating, now: now);
        expect(actual.due, expected.due);
        expect(actual.stability, expected.stability);
        expect(actual.difficulty, expected.difficulty);
        expect(engine.preview(card, now: now)[rating], expected.due);
      }
    },
  );

  test(
    'learning stability clamps at Good weight and preserves lower values',
    () {
      final engine = FsrsEngine();
      final scheduler = fsrs.Scheduler(enableFuzzing: false);
      final goodWeight = fsrs.defaultParameters[2];
      final betweenWeights = (fsrs.defaultParameters[1] + goodWeight) / 2;
      final last = now.subtract(const Duration(minutes: 10));
      for (final input in [betweenWeights, goodWeight, goodWeight + 30]) {
        final card = testCard(
          state: 1,
          stability: input,
          difficulty: 7.4,
          due: now,
          lastReview: last,
        );
        for (final rating in fsrs.Rating.values) {
          final expected = scheduler
              .reviewCard(
                fsrs.Card(
                  cardId: card.id,
                  state: fsrs.State.learning,
                  step: 1,
                  stability: input > goodWeight ? goodWeight : input,
                  difficulty: 7.4,
                  due: now,
                  lastReview: last,
                ),
                rating,
                reviewDateTime: now,
              )
              .card;
          final actual = engine.review(card, rating, now: now);
          expect(
            actual.stability,
            expected.stability,
            reason: 'input=$input, $rating',
          );
          expect(actual.due, expected.due);
        }
      }
    },
  );

  test(
    'controller preview freezes its own clock and rating uses the tap instant',
    () async {
      SharedPreferences.setMockInitialValues({});
      var wallClock = now;
      var engineReads = 0;
      final engine = FsrsEngine(
        clock: () {
          engineReads++;
          return now.add(const Duration(days: 100));
        },
      );
      final card = testCard(
        state: 2,
        stability: 17,
        difficulty: 8.2,
        due: now,
        lastReview: now.subtract(const Duration(days: 13)),
      );
      final api = FakeRecallApi([card])..failApplyReview = true;
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: store,
        clock: () => wallClock,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final preview = Map.of(controller.previewCurrent());
      expect(preview, engine.preview(card, now: now));
      expect(controller.previewCurrentAt, now);
      wallClock = now.add(const Duration(hours: 2));
      expect(controller.previewCurrent(), preview);
      expect(controller.previewCurrentAt, now);
      controller.flip();
      await controller.rate(fsrs.Rating.good);
      final entry = (await store.outbox()).single;
      expect(entry['last_review'], wallClock.toIso8601String());
      expect(
        entry['due'],
        engine
            .review(card, fsrs.Rating.good, now: wallClock)
            .due
            .toIso8601String(),
      );
      expect(engineReads, 0);
    },
  );

  test('rating a card due exactly now reduces the global due count', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi([
      testCard(
        state: 2,
        stability: 10,
        difficulty: 5,
        due: now,
        lastReview: now.subtract(const Duration(days: 5)),
      ),
    ])..deckCounts = {1: (due: 1, neu: 0)};
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.globalDueCount, 1);
    controller.flip();
    await controller.rate(fsrs.Rating.good);
    expect(controller.state.globalDueCount, 0);
  });

  test(
    'activity includes the exact two-day cutoff and excludes older reviews',
    () async {
      SharedPreferences.setMockInitialValues({});
      final cutoff = now.subtract(const Duration(days: 2));
      final api = FakeRecallApi([])
        ..reviewLog = [
          ReviewLogEntry(
            at: cutoff.subtract(const Duration(microseconds: 1)),
            rating: 3,
          ),
          ReviewLogEntry(at: cutoff, rating: 3),
        ];
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.state.reviewActivityKnown, isTrue);
      expect(controller.state.lastReviewedAt, cutoff.toLocal());
    },
  );
}

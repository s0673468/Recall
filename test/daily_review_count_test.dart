import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/daily_review_event.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/domain/study_day.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';

import 'support/recall_test_harness.dart';

// Synthetic rows only. The API test uses MockClient with an empty key; all
// controller tests share an in-process fake server, never a network service.
final _today = DateTime.utc(2026, 10, 24, 12);
Map<String, dynamic> _pending(String id, {DateTime? at, int rating = 1}) => {
  'client_id': id,
  'card_id': 1,
  'guid': 'synthetic',
  'device': 'synthetic-device',
  'rating': rating,
  'last_review': (at ?? _today).toIso8601String(),
};

class _RefuseDailyCache extends InMemorySharedPreferencesStore {
  _RefuseDailyCache() : super.empty();
  bool refuse = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (refuse && key.contains('recall_daily_reviews_v1')) {
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

class _HistoryApi extends FakeRecallApi {
  _HistoryApi(super.queue, {super.server});
  Completer<void>? historyWait;
  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    if (failReviewLog) throw StateError('synthetic offline history');
    final rows = server.reviewLog
        .map(
          (row) => ReviewLogEntry(
            id: row['id'] as int,
            cardId: row['card_id'] as int,
            clientEventId: row['client_event_id'] as String?,
            device: row['device'] as String?,
            at: DateTime.parse(row['rating_at'] as String),
            rating: row['rating'] as int,
          ),
        )
        .toList();
    await historyWait?.future;
    return rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ReviewController build(
    _HistoryApi api, {
    LocalReviewStore? store,
    DateTime Function()? clock,
  }) {
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store ?? LocalReviewStore(),
      clock: clock ?? () => _today,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> offline(_HistoryApi api, ReviewController controller) async {
    await controller.load();
    api.beforeQueue = () async => throw StateError('synthetic offline queue');
    api.failReviewLog = true;
    await controller.refresh();
    expect(controller.state.offline, isTrue);
  }

  test('restores stored history across restart and a second device', () async {
    final api = _HistoryApi([testCard()]);
    api.server.appendLog(_pending('one'), clientEventId: 'one');
    api.server.appendLog(_pending('two'), clientEventId: 'two');
    api.server.appendLog(
      _pending('yesterday', at: _today.subtract(const Duration(days: 1))),
      clientEventId: 'yesterday',
    );
    final first = build(api);
    await first.load();
    expect(first.state.reviewedToday, 2);
    final restart = build(api);
    await restart.load();
    expect(restart.state.reviewedToday, 2);
    // Empty synthetic preferences model a second device's fresh cache.
    SharedPreferences.setMockInitialValues({});
    final otherStore = LocalReviewStore();
    final other = build(
      _HistoryApi([testCard()], server: api.server),
      store: otherStore,
    );
    await other.load();
    expect(other.state.reviewedToday, 2);
    expect(other.state.reviewedThisSession, 0);
  });

  test(
    'cached cloud history remains available on an offline restart',
    () async {
      final api = _HistoryApi([testCard()]);
      api.server.appendLog(_pending('cloud'), clientEventId: 'cloud');
      await build(api).load();
      api.failReviewLog = true;
      api.beforeQueue = () async => throw StateError('synthetic offline');
      final restart = build(api, store: LocalReviewStore());
      await restart.load();
      expect(restart.state.reviewedToday, 1);
    },
  );

  test(
    'Again counts immediately, survives offline restart, syncs once',
    () async {
      final api = _HistoryApi([testCard(), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await offline(api, controller);
      controller.flip();
      await controller.rate(Rating.again);
      expect(controller.state.reviewedToday, 1);
      api.failApplyReview = true;
      final restart = build(api, store: LocalReviewStore());
      await restart.load();
      expect(restart.state.reviewedToday, 1);
      api.failApplyReview = false;
      await restart.syncPending();
      expect(await store.outbox(), isEmpty);
      expect(restart.state.reviewedToday, 1);
      // Even offline after the ACK, the accepted event remains cached.
      final afterAck = build(api);
      await afterAck.load();
      expect(afterAck.state.reviewedToday, 1);
      api.failReviewLog = false;
      api.beforeQueue = null;
      await afterAck.refresh();
      expect(afterAck.state.reviewedToday, 1);
      expect(api.server.reviewLog, hasLength(1));
    },
  );

  test(
    'server row and still queued event are counted once by client_event_id',
    () async {
      final api = _HistoryApi([testCard()])..failApplyReview = true;
      api.server.appendLog(_pending('same'), clientEventId: 'same');
      final store = LocalReviewStore();
      await store.enqueueReview(_pending('same'));
      await store.enqueueReview(_pending('same'));
      final controller = build(api, store: store);
      await controller.load();
      expect(controller.state.pendingSync, 1);
      expect(controller.state.reviewedToday, 1);
    },
  );

  test(
    'legacy server row and pending review share their original identity',
    () async {
      final api = _HistoryApi([testCard()])..failApplyReview = true;
      final pending = _pending('legacy')..remove('client_id');
      api.server.appendLog(pending);
      final store = LocalReviewStore();
      await store.enqueueReview(pending);
      final controller = build(api, store: store);
      await controller.load();
      expect(controller.state.reviewedToday, 1);
    },
  );

  test(
    'undo decrements durable pending count and stays undone after restart',
    () async {
      final api = _HistoryApi([testCard()]);
      final controller = build(api);
      await offline(api, controller);
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.reviewedToday, 1);
      await controller.undo();
      expect(controller.state.reviewedToday, 0);
      final restart = build(api);
      await restart.load();
      expect(restart.state.reviewedToday, 0);
    },
  );

  test(
    'history response begun before a local rating cannot lose that review',
    () async {
      final api = _HistoryApi([testCard(), testCard(id: 2)]);
      final controller = build(api);
      await controller.load();
      api.historyWait = Completer<void>();
      final refresh = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      api.historyWait!.complete();
      await refresh;
      expect(controller.state.reviewedToday, 1);
    },
  );

  for (final reason in ['dislike', 'delete']) {
    test('$reason hide and its undo do not count as reviews', () async {
      final api = _HistoryApi([testCard(), testCard(id: 2)])
        ..failApplyFlag = true;
      final controller = build(api);
      await controller.load();
      await controller.hideCurrent(reason);
      expect(controller.state.reviewedToday, 0);
      await controller.undo();
      expect(controller.state.reviewedToday, 0);
    });
  }

  test('likes and flags have no rated-review event', () {
    for (final op in ['like', 'dislike', 'delete']) {
      expect(
        DailyReviewEvent.fromPending({
          'op': op,
          'client_id': 'flag',
          'flagged_at': _today.toIso8601String(),
        }),
        isNull,
      );
    }
  });

  test('midnight Sao Paulo ignores UTC and device calendar dates', () {
    final boundary = DateTime.utc(2026, 10, 25, 3);
    final before = boundary.subtract(const Duration(microseconds: 1));
    expect(StudyDay.start(before), DateTime.utc(2026, 10, 24, 3));
    expect(StudyDay.start(boundary), boundary);
    expect(StudyDay.contains(before, boundary), isFalse);
    expect(StudyDay.contains(boundary, boundary), isTrue);
    // Same instants expressed in Japan; host/device ambient zone is irrelevant.
    expect(
      StudyDay.start(DateTime.parse('2026-10-25T11:59:59+09:00')),
      StudyDay.start(before),
    );
    expect(
      StudyDay.start(DateTime.parse('2026-10-25T12:00:00+09:00')),
      boundary,
    );
  });

  test(
    'open controller rolls count over and undo cannot subtract yesterday from today',
    () async {
      var now = DateTime.utc(2026, 10, 25, 2, 59, 59);
      final api = _HistoryApi([testCard()]);
      final controller = build(api, clock: () => now);
      await offline(api, controller);
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.reviewedToday, 1);
      now = DateTime.utc(2026, 10, 25, 3);
      expect(controller.state.reviewedToday, 0);
      await controller.undo();
      expect(controller.state.reviewedToday, 0);
    },
  );

  test(
    'scheduler introduction budget and history read use the shared rule',
    () async {
      final requests = <Uri>[];
      final now = DateTime.parse('2026-10-25T11:59:59+09:00');
      final client = SupabaseClient(
        'https://synthetic.invalid',
        '',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request.url);
          final q = request.url.queryParameters;
          final rows =
              request.url.path.endsWith('/review_log') &&
                  q['select']!.contains('rating_at') &&
                  q['or'] == null
              ? [
                  {
                    'id': 1,
                    'card_id': 1,
                    'client_event_id': 'cloud',
                    'device': 'synthetic',
                    'rating_at': now.toIso8601String(),
                    'rating': 1,
                  },
                ]
              : [];
          return http.Response(
            jsonEncode(rows),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final api = RecallApi(client, clock: () => now);
      await api.fetchQueue();
      final budget = requests.firstWhere(
        (uri) => uri.path.endsWith('/review_log'),
      );
      expect(budget.queryParametersAll['rating_at'], [
        'gte.2026-10-24T03:00:00.000Z',
        'lt.2026-10-25T03:00:00.000Z',
      ]);
      final log = await api.fetchReviewLog();
      expect(log.single.clientEventId, 'cloud');
      expect(DailyReviewEvent.fromLog(log.single)!.key, 'event:cloud');
    },
  );

  test(
    'lost server acknowledgement counts once before and after retry',
    () async {
      final api = _HistoryApi([testCard()])..commitThenThrowReview = true;
      final controller = build(api);
      await controller.load();
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(controller.state.reviewedToday, 1);
      expect(api.server.reviewLog, hasLength(1));
      await controller.refresh();
      expect(controller.state.reviewedToday, 1);
      expect(api.server.reviewLog, hasLength(1));
    },
  );

  test(
    'a fresh server history replaces cached rows removed by remote undo',
    () async {
      final api = _HistoryApi([testCard()]);
      final id = api.server.appendLog(
        _pending('remote'),
        clientEventId: 'remote',
      );
      final controller = build(api);
      await controller.load();
      expect(controller.state.reviewedToday, 1);
      api.server.deleteLog(id);
      await controller.refresh();
      expect(controller.state.reviewedToday, 0);
    },
  );

  test(
    'accepted receipts survive a stale history response until observed',
    () async {
      final store = LocalReviewStore();
      final event = DailyReviewEvent.fromPending(_pending('accepted'))!;
      await store.dailyReviewEvents(now: _today, merge: [event.receipt]);
      expect(
        await store.dailyReviewEvents(now: _today, replaceCloud: true),
        hasLength(1),
      );
      await store.dailyReviewEvents(
        now: _today,
        merge: [event],
        replaceCloud: true,
      );
      expect(
        await store.dailyReviewEvents(now: _today, replaceCloud: true),
        isEmpty,
      );
    },
  );

  test(
    'cache refusal keeps an accepted review durably queued until safe ACK',
    () async {
      final native = _RefuseDailyCache();
      SharedPreferencesStorePlatform.instance = native;
      final api = _HistoryApi([testCard()]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await offline(api, controller);
      controller.flip();
      await controller.rate(Rating.good);
      native.refuse = true;
      await expectLater(
        controller.syncPending(),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(await store.outbox(), hasLength(1));
      expect(controller.state.reviewedToday, 1);
      native.refuse = false;
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      expect(controller.state.reviewedToday, 1);
      expect(api.server.reviewLog, hasLength(1));
    },
  );

  test('daily cache is account scoped and cleared with that account', () async {
    final store = LocalReviewStore();
    await store.activateOwner('synthetic-owner-one');
    final event = DailyReviewEvent.fromPending(_pending('one'))!;
    await store.dailyReviewEvents(now: _today, merge: [event]);
    await store.activateOwner('synthetic-owner-two');
    expect(await store.dailyReviewEvents(now: _today), isEmpty);
    await store.activateOwner('synthetic-owner-one');
    expect(await store.dailyReviewEvents(now: _today), hasLength(1));
    await store.clear();
    expect(await store.dailyReviewEvents(now: _today), isEmpty);
  });

  test(
    'refresh removes a pending review undone by another local instance',
    () async {
      final store = LocalReviewStore();
      await store.enqueueReview(_pending('unsent'));
      final api = _HistoryApi([testCard()])..failApplyReview = true;
      // Prevent startup transport from closing Undo for this synthetic entry.
      final cached = await store.dailyReviewEvents(now: _today);
      expect(cached, hasLength(1));
      final other = LocalReviewStore();
      expect((await other.removeEntry('unsent')).removed, isTrue);
      final controller = build(api, store: store);
      await controller.load();
      expect(controller.state.reviewedToday, 0);
    },
  );

  testWidgets(
    'visible daily total resets at Sao Paulo midnight without interaction',
    (tester) async {
      var now = DateTime.utc(2026, 10, 25, 2, 59, 59);
      final api = _HistoryApi([testCard()]);
      api.server.appendLog(
        _pending('before', at: now),
        clientEventId: 'before',
      );
      final controller = build(api, clock: () => now);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );
      expect(find.text('1 done'), findsOneWidget);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0 done'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Settings explains the common daily reset', (tester) async {
    final api = _HistoryApi([testCard()]);
    final controller = build(api);
    final prefs = RecallPrefsController(api: api);
    addTearDown(prefs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(prefs: prefs, controller: controller),
      ),
    );
    expect(find.text(StudyDay.resetDescription), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Study header renders saved daily total instead of session total',
    (tester) async {
      final api = _HistoryApi([testCard()]);
      api.server.appendLog(_pending('stored'), clientEventId: 'stored');
      final controller = build(api);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );
      expect(find.text('1 done'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('1 card reviewed today'), findsOneWidget);
      expect(
        find.bySemanticsLabel('0 cards reviewed this session'),
        findsOneWidget,
      );
      semantics.dispose();
      expect(controller.state.reviewedThisSession, 0);
    },
  );
}

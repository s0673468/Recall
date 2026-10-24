import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/daily_review_event.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 24, 12);
Map<String, dynamic> _pending(String id) => {
  'client_id': id,
  'card_id': 1,
  'rating': 1,
  'last_review': _now.toIso8601String(),
};
User _user(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: _now.toIso8601String(),
);

class _HistoryApi extends FakeRecallApi {
  _HistoryApi({bool empty = false})
    : super(empty ? [] : [testCard(), testCard(id: 2)]) {
    user = _user('synthetic-owner');
  }
  List<ReviewLogEntry> history = [];
  Completer<void>? wait;
  Completer<void>? started;
  int reads = 0;
  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    reads++;
    final rows = List<ReviewLogEntry>.of(history);
    started?.complete();
    await wait?.future;
    if (failReviewLog) throw StateError('synthetic offline');
    return rows;
  }
}

// Hold a stale snapshot after reading native truth, exactly where another
// instance used to write an ACK receipt that the stale replacement erased.
class _PausedCacheRead extends InMemorySharedPreferencesStore {
  _PausedCacheRead() : super.empty();
  bool pause = false;
  final read = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final values = await super.getAllWithParameters(parameters);
    if (pause &&
        parameters.filter.allowList!.any(
          (key) => key.contains('recall_daily_reviews_v1'),
        )) {
      pause = false;
      read.complete();
      await release.future;
    }
    return values;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ReviewController build(_HistoryApi api) {
    final controller = ReviewController(
      api: api,
      store: LocalReviewStore(),
      engine: FsrsEngine(),
      clock: () => _now,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'resume refreshes seven remote reviews without disturbing active study',
    () async {
      final api = _HistoryApi();
      final controller = build(api);
      await controller.load();
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      controller.flip();
      final before = controller.state;
      final couldUndo = controller.canUndo;
      api.history = [
        for (var i = 0; i < 7; i++)
          ReviewLogEntry(
            id: i + 10,
            cardId: i + 10,
            clientEventId: 'synthetic-remote-$i',
            at: _now,
            rating: 1,
          ),
      ];
      await controller.refreshIfIdle();
      expect(controller.state.reviewedToday, 8);
      expect(controller.state.current, same(before.current));
      expect(controller.state.queue, same(before.queue));
      expect(controller.state.showBack, before.showBack);
      expect(controller.canUndo, couldUndo);
      expect(controller.state.reviewedThisSession, before.reviewedThisSession);
      expect(api.queueFetches, 1);

      api.failReviewLog = true;
      await controller.refreshIfIdle();
      expect(controller.state.reviewedToday, 8);
      expect(controller.state.current, same(before.current));
    },
  );

  test('fresh idle aggregate still refreshes remote daily count', () async {
    final api = _HistoryApi(empty: true);
    final controller = build(api);
    await controller.load();
    api.history = [ReviewLogEntry(id: 1, cardId: 1, at: _now, rating: 4)];
    await controller.refreshIfIdle();
    expect(controller.state.reviewedToday, 1);
    expect(api.queueFetches, 1);
  });

  test('concurrent foreground refreshes share one history read', () async {
    final api = _HistoryApi();
    final controller = build(api);
    await controller.load();
    api.wait = Completer<void>();
    api.started = Completer<void>();
    final first = controller.refreshIfIdle();
    await api.started!.future;
    final second = controller.refreshIfIdle();
    api.wait!.complete();
    await Future.wait([first, second]);
    expect(api.reads, 2); // startup and one foreground read
  });

  test(
    'history from a previous account cannot update a resumed session',
    () async {
      final api = _HistoryApi();
      final controller = build(api);
      await controller.load();
      api.history = [ReviewLogEntry(id: 1, cardId: 1, at: _now, rating: 4)];
      api.wait = Completer<void>();
      api.started = Completer<void>();
      final resume = controller.refreshIfIdle();
      await api.started!.future;
      api.user = _user('synthetic-other-owner');
      api.wait!.complete();
      await resume;
      expect(controller.state.reviewedToday, 0);
    },
  );

  test(
    'stale cache replacement and another store ACK preserve the receipt after restart',
    () async {
      final native = _PausedCacheRead();
      SharedPreferencesStorePlatform.instance = native;
      final first = LocalReviewStore();
      final second = LocalReviewStore();
      final pending = _pending('synthetic-accepted');
      await second.enqueueReview(pending);
      native.pause = true;
      final replacement = first.dailyReviewEvents(
        now: _now,
        replaceCloud: true,
      );
      await native.read.future;
      final ack = () async {
        await second.dailyReviewEvents(
          now: _now,
          merge: [DailyReviewEvent.fromPending(pending)!.receipt],
          includePending: false,
          requirePersistence: true,
        );
        await second.removeAcknowledgedReviews([pending]);
      }();
      // Let the competing store reach the old race before releasing the reader.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      native.release.complete();
      await Future.wait([replacement, ack]);
      expect(await second.outbox(), isEmpty);
      final restart = await LocalReviewStore().dailyReviewEvents(now: _now);
      expect(restart.map((event) => event.key), ['event:synthetic-accepted']);
    },
  );
}

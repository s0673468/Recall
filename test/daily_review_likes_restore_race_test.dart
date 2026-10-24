import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/daily_review_event.dart';

import 'support/recall_test_harness.dart';

class _HeldLikesRestore extends LocalReviewStore {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> likedFlags({String? ownerScope}) async {
    final cached = await super.likedFlags(ownerScope: ownerScope);
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return cached;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'superseded likes restore preserves the newer daily count and queue',
    () async {
      final now = DateTime.utc(2026, 10, 24, 12);
      final store = _HeldLikesRestore();
      DailyReviewEvent receipt(int id) => DailyReviewEvent.fromPending({
        'client_id': 'synthetic-accepted-$id',
        'card_id': id,
        'rating': 1,
        'last_review': now.toIso8601String(),
      })!;
      await store.dailyReviewEvents(now: now, merge: [receipt(3).receipt]);
      final api = FakeRecallApi([testCard(), testCard(id: 2)])
        ..failReviewLog = true;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      addTearDown(() {
        if (!store.release.isCompleted) store.release.complete();
      });

      final first = controller.load();
      await store.started.future;
      expect(controller.state.reviewedToday, 1);
      await store.dailyReviewEvents(now: now, merge: [receipt(4).receipt]);
      await controller.refresh();
      final queue = controller.state.queue;
      expect(controller.state.reviewedToday, 2);
      expect(api.queueFetches, 1);

      store.release.complete();
      await first;
      expect(controller.state.reviewedToday, 2);
      expect(controller.state.queue, same(queue));
      expect(api.queueFetches, 1);
    },
  );
}

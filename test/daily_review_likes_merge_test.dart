import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/daily_review_event.dart';

import 'support/recall_test_harness.dart';

class _HeldDailyCache extends LocalReviewStore {
  final dailyReadStarted = Completer<void>();
  final releaseDailyRead = Completer<void>();
  int likedReads = 0;

  @override
  Future<List<DailyReviewEvent>> dailyReviewEvents({
    required DateTime now,
    Iterable<DailyReviewEvent> merge = const [],
    bool replaceCloud = false,
    bool requirePersistence = false,
    bool includePending = true,
    String? ownerScope,
  }) async {
    if (!dailyReadStarted.isCompleted) {
      dailyReadStarted.complete();
      await releaseDailyRead.future;
    }
    return super.dailyReviewEvents(
      now: now,
      merge: merge,
      replaceCloud: replaceCloud,
      requirePersistence: requirePersistence,
      includePending: includePending,
      ownerScope: ownerScope,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> likedFlags({String? ownerScope}) {
    likedReads++;
    return super.likedFlags(ownerScope: ownerScope);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('superseded daily restore cannot start a new likes restore', () async {
    final store = _HeldDailyCache();
    final controller = ReviewController(
      api: FakeRecallApi([testCard()]),
      engine: FsrsEngine(),
      store: store,
    );
    addTearDown(controller.dispose);
    addTearDown(() {
      if (!store.releaseDailyRead.isCompleted) {
        store.releaseDailyRead.complete();
      }
    });
    final first = controller.load();
    await store.dailyReadStarted.future;
    await controller.refresh();
    expect(store.likedReads, 1);
    store.releaseDailyRead.complete();
    await first;
    expect(store.likedReads, 1);
  });

  test('offline restart restores daily reviews and likes together', () async {
    final now = DateTime.utc(2026, 10, 24, 12);
    final cards = [testCard(), testCard(id: 2)];
    final api = FakeRecallApi(cards)
      ..failReviewLog = true
      ..failFetchHidden = true
      ..beforeQueue = () async => throw StateError('synthetic offline');
    final store = LocalReviewStore();
    final reviewed = DailyReviewEvent.fromPending({
      'client_id': 'synthetic-accepted-review',
      'card_id': 3,
      'rating': 1,
      'last_review': now.toIso8601String(),
    })!;
    await store.dailyReviewEvents(now: now, merge: [reviewed.receipt]);
    await store.replaceLikedFlags([
      {'card_id': 1, 'reason': 'like', 'client_id': 'synthetic-cached-like'},
    ]);
    await store.saveSnapshot(decks: api.decks, queue: cards);

    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();

    expect(controller.state.offline, isTrue);
    expect(controller.state.current?.id, 1);
    expect(controller.currentLiked, isTrue);
    expect(controller.state.reviewedToday, 1);

    await controller.toggleLike();
    expect(controller.currentLiked, isFalse);
    expect(controller.state.reviewedToday, 1);
    expect(await store.outbox(), isEmpty);

    controller.flip();
    await controller.rate(Rating.again);
    expect(controller.state.reviewedToday, 2);
    await controller.undo();
    expect(controller.state.reviewedToday, 1);
    expect(controller.state.current?.id, 1);
    expect(controller.currentLiked, isFalse);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({ReviewController controller, FakeRecallApi api, LocalReviewStore store})
  >
  session({int cards = 5}) async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.utc(2026, 10, 26, 12);
    final api = FakeRecallApi([
      for (var id = 1; id <= cards; id++)
        testCard(id: id, state: 2, due: now.subtract(const Duration(days: 1))),
    ]);
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: () => now,
      reviewSyncDelay: ReviewController.interactiveReviewSyncDelay,
      reviewUndoLimit: ReviewController.interactiveReviewUndoLimit,
    );
    addTearDown(controller.dispose);
    await controller.load();
    return (controller: controller, api: api, store: store);
  }

  Future<void> rate(
    ReviewController controller, [
    Rating rating = Rating.good,
  ]) async {
    controller.flip();
    await controller.rate(rating);
    await controller.syncPending(preserveUndo: true);
  }

  test(
    'online ratings keep three durable corrections while older ones sync',
    () async {
      final (:controller, :api, :store) = await session();
      for (var i = 0; i < 4; i++) {
        await rate(controller);
      }
      expect(api.applied.map((entry) => entry['card_id']), [1]);
      expect((await store.outbox()).map((entry) => entry['card_id']), [
        2,
        3,
        4,
      ]);
      expect(
        (await store.outbox()).every(
          (entry) => entry['delivery_attempted'] == false,
        ),
        isTrue,
      );
      expect(controller.state.reviewedToday, 4);
      expect(controller.canUndo, isTrue);
      expect(controller.flagNotice, isNull);

      for (final id in [4, 3, 2]) {
        await controller.undo();
        expect(controller.state.current?.id, id);
        expect(controller.state.reviewedToday, id - 1);
      }
      expect(controller.canUndo, isFalse);
      expect(await store.outbox(), isEmpty);
      expect(api.applied.map((entry) => entry['card_id']), [1]);

      await rate(controller, Rating.again);
      expect((await store.outbox()).single['rating'], Rating.again.value);
      expect(controller.state.reviewedToday, 2);
    },
  );

  testWidgets(
    'a one-minute pause syncs quietly and ends the correction window',
    (tester) async {
      final (:controller, :api, :store) = await session(cards: 1);
      await rate(controller);
      await tester.pump(const Duration(seconds: 59));
      expect(api.applied, isEmpty);
      expect(controller.canUndo, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await controller.syncPending(preserveUndo: true);
      expect(api.applied, hasLength(1));
      expect(await store.outbox(), isEmpty);
      expect(controller.canUndo, isFalse);
      expect(controller.flagNotice, isNull);
      expect(controller.state.reviewedToday, 1);
    },
  );

  testWidgets('another rating restarts the idle delay', (tester) async {
    final (:controller, :api, :store) = await session();
    await rate(controller);
    await tester.pump(const Duration(seconds: 50));
    await rate(controller);
    await tester.pump(const Duration(seconds: 10));
    expect(api.applied, isEmpty);
    expect(await store.outbox(), hasLength(2));
    await tester.pump(const Duration(seconds: 50));
    await controller.syncPending(preserveUndo: true);
    expect(api.applied, hasLength(2));
    expect(controller.flagNotice, isNull);
  });

  test('explicit sync safely closes undo without a transient notice', () async {
    final (:controller, :api, :store) = await session();
    await rate(controller);
    await controller.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(api.applied, hasLength(1));
    expect(controller.canUndo, isFalse);
    expect(controller.flagNotice, isNull);
  });

  test(
    'automatic idle refresh preserves the last-card correction window',
    () async {
      final (:controller, :api, :store) = await session(cards: 1);
      api.user = testUser('synthetic-owner');
      await rate(controller);
      expect(controller.state.isDone, isTrue);
      await controller.refreshIfIdle(maxAge: Duration.zero);
      expect(controller.canUndo, isTrue);
      expect(await store.outbox(), hasLength(1));
      expect(api.applied, isEmpty);
      await controller.undo();
      expect(controller.state.current?.id, 1);
    },
  );

  test('sign-out drains held ratings before clearing the session', () async {
    final (:controller, :api, :store) = await session();
    await rate(controller);
    await rate(controller);
    await controller.signOut();
    expect(api.applied.map((entry) => entry['card_id']), [1, 2]);
    expect(await store.outbox(), isEmpty);
    expect(api.signedOut, isTrue);
  });

  testWidgets('an idle timer cannot send after the account changes', (
    tester,
  ) async {
    final (:controller, :api, :store) = await session();
    api.user = testUser('synthetic-owner-a');
    await rate(controller);
    api.user = testUser('synthetic-owner-b');
    await tester.pump(const Duration(minutes: 1));
    expect(api.applied, isEmpty);
    expect(await store.outbox(), hasLength(1));
  });

  test('a restart replays held durable ratings exactly once', () async {
    final (:controller, :api, :store) = await session();
    await rate(controller);
    await rate(controller);
    // A fresh controller has none of the previous controller's undo memory.
    expect(await store.outbox(), hasLength(2));
    final restarted = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
    );
    addTearDown(restarted.dispose);
    await restarted.load();
    await restarted.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(api.applied.map((entry) => entry['card_id']), [1, 2]);
    expect(api.server.reviewLog, hasLength(2));
  });

  test(
    'a failed older send cannot consume the latest three corrections',
    () async {
      final (:controller, :api, :store) = await session();
      api.beforeApplyReview = () async =>
          throw StateError('Synthetic offline send');
      for (var i = 0; i < 4; i++) {
        await rate(controller);
      }
      expect(controller.state.offline, isTrue);
      expect((await store.outbox()).first['delivery_attempted'], isTrue);
      for (final id in [4, 3, 2]) {
        await controller.undo();
        expect(controller.state.current?.id, id);
      }
      expect((await store.outbox()).single['card_id'], 1);
      expect(controller.canUndo, isFalse);
      expect(api.applied, isEmpty);
    },
  );

  test('an older send in flight leaves later ratings undoable', () async {
    final (:controller, :api, :store) = await session();
    for (var i = 0; i < 3; i++) {
      await rate(controller);
    }
    final sending = Completer<void>();
    final release = Completer<void>();
    api.beforeApplyReview = () {
      if (!sending.isCompleted) sending.complete();
      return release.future;
    };
    controller.flip();
    await controller.rate(Rating.good);
    await sending.future;
    expect(controller.canUndo, isTrue);
    final undo = controller.undo();
    release.complete();
    await undo;
    expect(controller.state.current?.id, 4);
    expect((await store.outbox()).map((entry) => entry['card_id']), [2, 3]);
    expect(api.applied.map((entry) => entry['card_id']), [1]);
  });

  testWidgets('resuming study during an idle flush protects the new window', (
    tester,
  ) async {
    final (:controller, :api, :store) = await session();
    for (var i = 0; i < 3; i++) {
      await rate(controller);
    }
    final release = Completer<void>();
    var attempts = 0;
    api.beforeApplyReview = () {
      attempts++;
      return release.future;
    };
    await tester.pump(const Duration(minutes: 1));
    expect(attempts, 1);
    controller.flip();
    await controller.rate(Rating.good);
    release.complete();
    await controller.syncPending(preserveUndo: true);
    expect(api.applied.map((entry) => entry['card_id']), [1]);
    expect((await store.outbox()).map((entry) => entry['card_id']), [2, 3, 4]);
    expect(
      (await store.outbox()).every(
        (entry) => entry['delivery_attempted'] == false,
      ),
      isTrue,
    );
    await controller.undo();
    await controller.undo();
    await controller.undo();
    expect(controller.state.current?.id, 2);
    expect(await store.outbox(), isEmpty);
  });
}

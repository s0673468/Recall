import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final now = DateTime.utc(2031, 1, 2, 12);
  const validationId = 91;

  Future<(ReviewController, FakeRecallApi, LocalReviewStore)> session({
    required bool active,
    bool offline = false,
    bool validationDue = false,
  }) async {
    final api = FakeRecallApi([
      testCard(
        id: validationId,
        state: 2,
        stability: 30,
        difficulty: 4,
        reps: 12,
        lapses: 2,
        due: validationDue
            ? now.subtract(const Duration(days: 1))
            : DateTime.utc(2032, 1, 1),
        lastReview: now.subtract(const Duration(days: 30)),
        tags: 'content_revalidate::20310101T120000Z',
        contentRevalidationPending: true,
      ),
      for (var id = 1; id <= 90; id++)
        testCard(
          id: id,
          state: 2,
          stability: 5,
          difficulty: 5,
          reps: 2,
          due: now.subtract(const Duration(days: 1)),
          lastReview: now.subtract(const Duration(days: 5)),
        ),
    ]);
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.catchUp.shouldOffer, isTrue);
    if (active) await controller.startCatchUp();
    if (offline) {
      api.beforeQueue = () async => throw StateError('Synthetic offline read');
      await controller.refresh();
      expect(controller.state.offline, isTrue);
    }
    expect(controller.state.current?.id, validationId);
    return (controller, api, store);
  }

  for (final active in [false, true]) {
    for (final validationDue in [false, true]) {
      test(
        'delivered ${validationDue ? 'due' : 'future'} validation Again stays out after ${active ? 'show all' : 'start catch-up'}',
        () async {
          final (controller, api, store) = await session(
            active: active,
            validationDue: validationDue,
          );
          final fetches = api.queueFetches;
          controller.flip();
          await controller.rate(Rating.again);
          await controller.syncPending();
          expect(await store.outbox(), isEmpty);
          expect(api.server.reviewLog.single['card_id'], validationId);
          expect(api.server.cards[validationId]!.lapses, 3);

          if (active) {
            await controller.showAll();
            expect(controller.state.catchUp.isDismissed, isTrue);
          } else {
            await controller.startCatchUp();
            expect(controller.state.catchUp.isActive, isTrue);
          }
          expect(controller.state.index, 0);
          expect(
            controller.state.queue.map((card) => card.id),
            isNot(contains(validationId)),
          );
          expect(api.queueFetches, fetches);
          expect(controller.state.catchUp.dueCount, 90);

          // A later snapshot write must still retain the unacknowledged
          // validation for a new offline session, without showing it here.
          controller.flip();
          await controller.rate(Rating.good);
          await controller.syncPending();
          expect(controller.state.catchUp.dueCount, 89);
          if (!active) await controller.showAll();
          expect(
            controller.state.queue
                .map((card) => card.id)
                .skip(controller.state.index),
            isNot(contains(validationId)),
          );
          expect(
            api.server.reviewLog.where((row) => row['card_id'] == validationId),
            hasLength(1),
          );
          final snapshot = await store.loadSnapshot();
          expect(
            snapshot!.queue
                .where((card) => card.id == validationId)
                .single
                .contentRevalidationPending,
            isTrue,
          );
        },
      );
    }
  }

  test(
    'pending Again survives catch-up choices and later snapshot writes',
    () async {
      final (controller, api, store) = await session(
        active: false,
        offline: true,
      );
      controller.flip();
      await controller.rate(Rating.again);
      await controller.startCatchUp();
      controller.flip();
      await controller.rate(Rating.good);
      expect(await store.outbox(), hasLength(2));
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      await controller.showAll();
      expect(
        controller.state.queue.map((card) => card.id),
        isNot(contains(validationId)),
      );
      final snapshot = await store.loadSnapshot();
      expect(snapshot!.queue.map((card) => card.id), contains(validationId));
      expect(
        api.server.reviewLog.where((row) => row['card_id'] == validationId),
        hasLength(1),
      );
    },
  );

  test(
    'a failed refresh keeps rated validations out of catch-up choices',
    () async {
      final (controller, api, store) = await session(active: false);
      controller.flip();
      await controller.rate(Rating.again);
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      api.beforeQueue = () async => throw StateError('Synthetic offline read');
      await controller.refresh();
      expect(controller.state.offline, isTrue);

      await controller.startCatchUp();
      expect(
        controller.state.queue.map((card) => card.id),
        isNot(contains(validationId)),
      );
      expect(api.server.reviewLog, hasLength(1));
    },
  );

  test(
    'a fresh load can present the still-pending validation with updated scheduling',
    () async {
      final (controller, api, store) = await session(active: false);
      controller.flip();
      await controller.rate(Rating.again);
      await controller.syncPending();
      await controller.startCatchUp();
      expect(
        controller.state.queue.map((card) => card.id),
        isNot(contains(validationId)),
      );

      await controller.load();
      expect(controller.state.current!.id, validationId);
      expect(controller.state.current!.lapses, 3);
      expect(controller.state.current!.reps, 13);
      expect(controller.state.current!.lastReview, now);
      expect(controller.state.current!.contentRevalidationPending, isTrue);
      expect(await store.outbox(), isEmpty);
      expect(api.server.reviewLog, hasLength(1));
    },
  );

  test(
    'offline Undo restores validation Again and its catch-up source',
    () async {
      final (controller, api, store) = await session(
        active: true,
        offline: true,
      );
      final original = controller.state.current!;
      final before = controller.state.catchUp;
      controller.flip();
      await controller.rate(Rating.again);
      expect(controller.state.current?.id, isNot(validationId));
      expect((await store.outbox()).single['card_id'], validationId);
      expect(controller.canUndo, isTrue);

      await controller.undo();
      expect(controller.state.current, same(original));
      expect(controller.state.current!.contentRevalidationPending, isTrue);
      expect(controller.state.current!.lapses, 2);
      expect(controller.state.reviewedThisSession, 0);
      expect(controller.state.catchUp.completedToday, before.completedToday);
      expect(await store.outbox(), isEmpty);
      expect(api.applied, isEmpty);

      // Rebuilding after Undo must include the restored card exactly once.
      await controller.showAll();
      expect(controller.state.current, same(original));
      expect(
        controller.state.queue.where((card) => card.id == validationId),
        hasLength(1),
      );
      controller.flip();
      await controller.rate(Rating.again);
      expect((await store.outbox()).single['card_id'], validationId);
      expect(controller.state.current?.id, isNot(validationId));
    },
  );
}

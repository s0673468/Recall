import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ReviewController build(FakeRecallApi api, LocalReviewStore store) {
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      haptics: const ReviewHaptics(),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  for (final rating in Rating.values) {
    test(
      'delivered ${rating.name} stays consumed after offline restart',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final store = LocalReviewStore();
        final controller = build(api, store);
        await controller.load();
        await store.outbox(); // finish the initial snapshot save
        controller.flip();
        await controller.rate(rating);
        await controller.syncPending();
        expect(api.applied, hasLength(1));
        expect(await store.outbox(), isEmpty);

        // Drop the controller and store, retaining only mock durable preferences.
        api.beforeQueue = () async => throw StateError('Invented offline read');
        final restarted = build(api, LocalReviewStore());
        await restarted.load();
        expect(restarted.state.offline, isTrue);
        expect(restarted.state.queue.map((card) => card.id), [2]);
        expect(restarted.canUndo, isFalse);
      },
    );
  }

  test(
    'delivered due card and completed queue stay consumed on restart',
    () async {
      final now = DateTime.utc(2026, 10, 21, 12);
      final api = FakeRecallApi([
        testCard(
          id: 1,
          state: 2,
          reps: 3,
          stability: 4,
          difficulty: 5,
          due: now.subtract(const Duration(days: 1)),
          lastReview: now.subtract(const Duration(days: 5)),
        ),
      ]);
      final store = LocalReviewStore();
      final controller = build(api, store);
      await controller.load();
      await store.outbox();
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      api.beforeQueue = () async => throw StateError('Invented offline read');
      final restarted = build(api, LocalReviewStore());
      await restarted.load();
      expect(restarted.state.offline, isTrue);
      expect(restarted.state.isDone, isTrue);
      expect(restarted.state.queue, isEmpty);
    },
  );

  test('bonus rating leaves the ordinary snapshot alone', () async {
    final api = FakeRecallApi([testCard(id: 1)]);
    final store = LocalReviewStore();
    final controller = build(api, store);
    await controller.load();
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();
    expect((await store.loadSnapshot())!.queue, isEmpty);
    await controller.keepGoing();
    expect(controller.state.current?.id, 1); // Near-due learning card.
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();
    expect((await store.loadSnapshot())!.queue, isEmpty);
  });

  test(
    'bonus undo after a failed refresh leaves the ordinary snapshot alone',
    () async {
      final api = FakeRecallApi([testCard(id: 1)]);
      final store = LocalReviewStore();
      final controller = build(api, store);
      await controller.load();
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      await controller.keepGoing();
      expect(controller.state.current?.id, 1);
      api.beforeQueue = () async => throw StateError('Invented offline read');
      await controller.refresh();
      expect(controller.state.offline, isTrue);
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.canUndo, isTrue);
      await controller.undo();
      await store.outbox();
      expect(controller.state.current?.id, 1);
      expect((await store.loadSnapshot())!.queue, isEmpty);
    },
  );

  test(
    'late cold-start fetch cannot cache a review delivered meanwhile',
    () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      await store.saveSnapshot(decks: api.decks, queue: api.queue);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      api.beforeQueue = () async {
        entered.complete();
        await release.future;
      };
      final controller = build(api, store);
      final loading = controller.load();
      await entered.future;
      expect(controller.state.loading, isFalse); // Cached card is studyable.
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      release.complete();
      await loading;
      await store.outbox();
      expect(controller.state.current?.id, 2);
      api.beforeQueue = () async => throw StateError('Invented offline read');
      final restarted = build(api, LocalReviewStore());
      await restarted.load();
      expect(restarted.state.queue.map((card) => card.id), [2]);
    },
  );

  test('undo restores consumed card to the offline restart snapshot', () async {
    final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
    final store = LocalReviewStore();
    final controller = build(api, store);
    await controller.load();
    await store.outbox();
    api.beforeQueue = () async => throw StateError('Invented offline read');
    await controller.refresh();
    controller.flip();
    await controller.rate(Rating.good);
    await store.outbox();
    expect((await store.loadSnapshot())!.queue.map((card) => card.id), [2]);
    await controller.undo();
    await store.outbox();
    expect(await store.outbox(), isEmpty);
    final restarted = build(api, LocalReviewStore());
    await restarted.load();
    expect(restarted.state.queue.map((card) => card.id), [1, 2]);
  });
}

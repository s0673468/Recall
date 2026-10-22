import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.utc(2026, 10, 21, 12);
  ReviewCard validationCard() => testCard(
    id: 91,
    state: 2,
    stability: 30,
    difficulty: 4,
    reps: 12,
    due: DateTime.utc(2027, 2, 1),
    lastReview: DateTime.utc(2026, 7, 1),
    tags: 'topic content_revalidate::20261020T120000Z',
    contentRevalidationPending: true,
  );

  ReviewController build(FakeRecallApi api, LocalReviewStore store) {
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  for (final rating in Rating.values) {
    test(
      'validation ${rating.name} survives later snapshot writes only if unacknowledged',
      () async {
        final api = FakeRecallApi([validationCard(), testCard(id: 92)]);
        final store = LocalReviewStore();
        final controller = build(api, store);
        await controller.load();
        expect(controller.state.current?.id, 91);
        controller.flip();
        await controller.rate(rating);
        await controller.syncPending();
        expect(await store.outbox(), isEmpty);
        expect(controller.state.current?.id, 92);

        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending();
        expect(await store.outbox(), isEmpty);
        expect(controller.state.isDone, isTrue);
        expect(api.server.reviewLog.map((row) => row['card_id']), [91, 92]);

        // Reconstruct both objects from durable preferences after delivery.
        api.beforeQueue = () async => throw StateError('Invented offline read');
        final restarted = build(api, LocalReviewStore());
        await restarted.load();
        expect(restarted.state.offline, isTrue);
        expect(
          restarted.state.queue.map((card) => card.id),
          rating == Rating.again ? [91] : isEmpty,
        );
        if (rating == Rating.again) {
          expect(restarted.state.current?.contentRevalidationPending, isTrue);
        }
      },
    );
  }

  test('pending Again survives a later snapshot write and reconnect', () async {
    final api = FakeRecallApi([validationCard(), testCard(id: 92)])
      ..failApplyReview = true;
    final store = LocalReviewStore();
    final controller = build(api, store);
    await controller.load();
    controller.flip();
    await controller.rate(Rating.again);
    await controller.syncPending();
    expect(await store.outbox(), hasLength(1));
    expect(controller.state.current?.id, 92);

    controller.flip();
    await controller.rate(Rating.good);
    expect(await store.outbox(), hasLength(2));
    // A still-pending review must not be offered again from the snapshot.
    api.beforeQueue = () async => throw StateError('Invented offline read');
    final pendingRestart = build(api, LocalReviewStore());
    await pendingRestart.load();
    expect(pendingRestart.state.offline, isTrue);
    expect(pendingRestart.state.queue, isEmpty);

    api.failApplyReview = false;
    await pendingRestart.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(api.server.reviewLog.map((row) => row['card_id']), [91, 92]);
    final restarted = build(api, LocalReviewStore());
    await restarted.load();
    expect(restarted.state.offline, isTrue);
    expect(restarted.state.queue.map((card) => card.id), [91]);
    expect(restarted.state.current?.contentRevalidationPending, isTrue);
  });
}

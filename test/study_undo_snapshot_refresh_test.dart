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

  for (final initialDueCount in [0, 2]) {
    test(
      'refresh preserves Undo snapshot and actual due-count change from $initialDueCount',
      () async {
        final now = DateTime.utc(2026, 10, 22, 12);
        final api = FakeRecallApi([
          for (final id in [501, 502])
            testCard(
              id: id,
              state: 2,
              reps: 3,
              stability: 4,
              difficulty: 5,
              due: now.subtract(const Duration(days: 1)),
              lastReview: now.subtract(const Duration(days: 5)),
            ),
        ]);
        final store = LocalReviewStore();
        await store.saveSnapshot(
          decks: api.decks,
          queue: api.queue,
          globalDueCount: initialDueCount,
          globalDueUpdatedAt: now,
        );
        ReviewController build(LocalReviewStore localStore) {
          final controller = ReviewController(
            api: api,
            engine: FsrsEngine(),
            store: localStore,
            clock: () => now,
            haptics: const ReviewHaptics(),
          );
          addTearDown(controller.dispose);
          return controller;
        }

        final controller = build(store);
        api.beforeQueue = () async =>
            throw StateError('Synthetic offline read');
        await controller.load();
        expect(controller.state.offline, isTrue);
        expect(controller.state.globalDueCount, initialDueCount);

        final entered = Completer<void>();
        final release = Completer<void>();
        api.beforeQueue = () async {
          entered.complete();
          await release.future;
        };
        final refresh = controller.refresh();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await refresh;
        });
        await entered.future;
        controller.flip();
        await controller.rate(Rating.good);
        expect(controller.canUndo, isTrue);
        expect(controller.state.globalDueCount, initialDueCount == 0 ? 0 : 1);

        // Completing the fetch rebuilds Undo's catch-up metadata. It must keep
        // both whether the count changed and whether the snapshot was pruned.
        release.complete();
        await refresh;
        expect(controller.canUndo, isTrue);
        expect(controller.state.current?.id, 502);
        expect((await store.loadSnapshot())!.queue.map((card) => card.id), [
          502,
        ]);
        expect(await store.outbox(), hasLength(1));
        expect(api.applied, isEmpty);

        await controller.undo();
        expect(controller.state.current?.id, 501);
        expect(controller.state.globalDueCount, initialDueCount);
        expect(await store.outbox(), isEmpty);
        final restored = (await store.loadSnapshot())!;
        expect(restored.queue.map((card) => card.id), [501, 502]);
        expect(restored.globalDueCount, initialDueCount);

        // Reconstruct from synthetic durable preferences to verify the result
        // at the offline-restart surface as well as in the active controller.
        api.beforeQueue = () async =>
            throw StateError('Synthetic offline read');
        final restarted = build(LocalReviewStore());
        await restarted.load();
        expect(restarted.state.offline, isTrue);
        expect(restarted.state.queue.map((card) => card.id), [501, 502]);
        expect(restarted.state.globalDueCount, initialDueCount);
      },
    );
  }
}

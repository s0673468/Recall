import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

// The catch-up offer is most likely after time away, which is also when a
// session is likely to open without a connection. Choosing "Start catch-up" or
// "Show all" only re-slices the cards already on the device; it proves nothing
// about the network. The session must stay offline so the next rating stays
// local and undoable instead of being handed to a dead network, and the header
// keeps saying why nothing syncs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 8, 5, 12);

  Future<(ReviewController, FakeRecallApi, LocalReviewStore, List<int>)>
  offeredWhileUnreachable(Object failure) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi(_catchUpQueue(82, now));
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

    // The connection drops; a refresh keeps the session on its queue and
    // the offer on screen.
    final attempts = <int>[];
    api.beforeQueue = () async => throw failure;
    api.beforeApplyReview = () async {
      attempts.add(attempts.length);
      throw failure;
    };
    await controller.refresh();
    expect(controller.state.offline, isTrue);
    expect(controller.state.catchUp.shouldOffer, isTrue);
    return (controller, api, store, attempts);
  }

  Future<void> expectLocalUndoableRating(
    ReviewController controller,
    FakeRecallApi api,
    LocalReviewStore store,
    List<int> attempts,
  ) async {
    final rated = controller.state.current!.id;
    controller.flip();
    await controller.rate(Rating.good);
    await Future<void>.delayed(Duration.zero);

    // No send was started, so the rating keeps its Undo and nobody is told
    // that it already synced.
    expect(attempts, isEmpty);
    expect(api.applied, isEmpty);
    expect(controller.flagNotice, isNull);
    expect(controller.canUndo, isTrue);
    expect(controller.state.pendingSync, 1);

    await controller.undo();
    expect(controller.state.current?.id, rated);
    expect(await store.outbox(), isEmpty);
    expect(controller.state.pendingSync, 0);
  }

  test('starting catch-up offline keeps the next rating local', () async {
    final (controller, api, store, attempts) = await offeredWhileUnreachable(
      StateError('offline'),
    );

    await controller.startCatchUp();

    expect(controller.state.catchUp.isActive, isTrue);
    expect(controller.state.offline, isTrue);
    await expectLocalUndoableRating(controller, api, store, attempts);
  });

  test(
    'showing all after a server error keeps its label and local ratings',
    () async {
      final (controller, api, store, attempts) = await offeredWhileUnreachable(
        const PostgrestException(message: 'invented', code: '503'),
      );
      expect(controller.state.serverError, isTrue);

      await controller.showAll();

      expect(controller.state.catchUp.isDismissed, isTrue);
      expect(controller.state.offline, isTrue);
      expect(controller.state.serverError, isTrue);
      await expectLocalUndoableRating(controller, api, store, attempts);
    },
  );

  test('a reconnect after an offline catch-up choice clears offline', () async {
    final (controller, api, store, _) = await offeredWhileUnreachable(
      StateError('offline'),
    );
    await controller.startCatchUp();
    controller.flip();
    await controller.rate(Rating.good);
    expect(controller.state.offline, isTrue);

    // Connectivity returns; the app-resume/browser path delivers the queue.
    api.beforeQueue = null;
    api.beforeApplyReview = null;
    await controller.syncPending();

    expect(api.applied, hasLength(1));
    expect(await store.outbox(), isEmpty);
    expect(controller.state.offline, isFalse);
    expect(controller.state.catchUp.isActive, isTrue);
    expect(controller.state.catchUp.completedToday, 1);
  });

  test('a catch-up choice online still syncs behind the UI', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi(_catchUpQueue(82, now));
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      clock: () => now,
    );
    addTearDown(controller.dispose);

    await controller.load();
    await controller.startCatchUp();
    expect(controller.state.offline, isFalse);

    controller.flip();
    await controller.rate(Rating.good);
    for (var i = 0; i < 1000 && api.applied.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.applied, hasLength(1));
  });
}

List<ReviewCard> _catchUpQueue(int count, DateTime now) => [
  for (var i = 0; i < count; i++)
    testCard(
      id: 1000 + i,
      state: 2,
      stability: (i + 1).toDouble(),
      difficulty: 5,
      due: now.subtract(Duration(hours: i + 1)),
      lastReview: now.subtract(Duration(days: i + 1)),
    ),
];

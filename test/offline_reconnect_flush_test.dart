import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

// A study session that loses its connection mid-way keeps rating offline, so
// each rating stays undoable instead of being handed to a dead network. Once a
// foreground or browser sync proves the server is reachable again, the session
// must stop treating itself as offline: the badge clears and later ratings sync
// behind the UI again instead of waiting for the next app resume.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 1000 && !condition(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(condition(), isTrue);
  }

  Future<(ReviewController, FakeRecallApi, LocalReviewStore)>
  offlineMidSession() async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi([
      testCard(id: 1),
      testCard(id: 2),
      testCard(id: 3),
    ]);
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.state.offline, isFalse);

    // The connection drops; a refresh keeps the session on its queue.
    api.beforeQueue = () async => throw StateError('offline fetch');
    api.beforeApplyReview = () async => throw StateError('offline');
    await controller.refresh();
    expect(controller.state.offline, isTrue);
    expect(controller.state.current?.id, 1);

    controller.flip();
    await controller.rate(Rating.good);
    // Offline ratings stay local and undoable; nothing reaches the network.
    expect(api.applied, isEmpty);
    expect(controller.canUndo, isTrue);
    expect(controller.state.pendingSync, 1);
    expect(await store.outbox(), hasLength(1));
    return (controller, api, store);
  }

  test(
    'a delivering sync clears offline so later ratings sync again',
    () async {
      final (controller, api, store) = await offlineMidSession();

      // Connectivity returns while card 2 is on screen. The app-resume (or
      // browser timer/online) path replays the outbox without a reload.
      api.beforeQueue = null;
      api.beforeApplyReview = null;
      await controller.syncPending();

      expect(api.applied.map((entry) => entry['card_id']), [1]);
      expect(await store.outbox(), isEmpty);
      expect(controller.state.pendingSync, 0);
      expect(controller.state.offline, isFalse);
      // The active card was not displaced by the sync.
      expect(controller.state.current?.id, 2);

      controller.flip();
      await controller.rate(Rating.good);
      await waitFor(() => api.applied.length == 2);
      expect(api.applied.map((entry) => entry['card_id']), [1, 2]);
      await waitFor(() => controller.state.pendingSync == 0);
      expect(await store.outbox(), isEmpty);
      expect(controller.state.offline, isFalse);
    },
  );

  test('a sync that still cannot deliver keeps the session offline', () async {
    final (controller, api, store) = await offlineMidSession();

    await controller.syncPending();

    expect(api.applied, isEmpty);
    expect(await store.outbox(), hasLength(1));
    expect(controller.state.pendingSync, 1);
    expect(controller.state.offline, isTrue);

    // Still offline: the next rating stays local rather than starting a
    // network attempt that would end its Undo window.
    controller.flip();
    await controller.rate(Rating.good);
    await Future<void>.delayed(Duration.zero);
    expect(api.applied, isEmpty);
    expect(controller.canUndo, isTrue);
    expect(controller.state.pendingSync, 2);
  });
}

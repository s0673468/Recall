import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

// A connection can die without failing: a dead zone or a stale pooled socket
// leaves a request open for minutes. The review send has no transport timeout
// of its own, and Undo, Keep going, Reload and sign-out all wait for a running
// send. One hung send must not freeze the study session; it gives up after a
// bound, stays queued, and the server's client_event_id makes the replay safe.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bound = Duration(milliseconds: 50);
  // Far longer than [bound]; only a send that is never given up on hits it.
  const guard = Duration(seconds: 5);

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 1000 && !condition(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(condition(), isTrue);
  }

  Future<(ReviewController, FakeRecallApi, LocalReviewStore, Completer<void>)>
  onlineSessionWithHungSend(int cards) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi([
      for (var id = 1; id <= cards; id++) testCard(id: id),
    ]);
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      reviewSendTimeout: bound,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.offline, isFalse);

    // The network dies silently: every send stays open until released.
    final hung = Completer<void>();
    api.beforeApplyReview = () => hung.future;
    return (controller, api, store, hung);
  }

  test('Undo during a hung send returns after the bound', () async {
    final (controller, api, store, hung) = await onlineSessionWithHungSend(3);
    var attempts = 0;
    api.beforeApplyReview = () {
      attempts++;
      return hung.future;
    };

    controller.flip();
    await controller.rate(Rating.good); // its send hangs
    await waitFor(() => attempts == 1);
    controller.flip();
    await controller.rate(Rating.again); // a mis-tap
    expect(controller.state.current?.id, 3);
    expect(controller.canUndo, isTrue);

    await controller.undo().timeout(
      guard,
      onTimeout: () => fail('Undo waited on a send that never returns'),
    );

    expect(controller.state.current?.id, 2);
    expect(controller.canUndo, isFalse);
    expect(controller.undoInFlight, isFalse);
    // Only card 1 stays queued; card 2's mis-tap is gone.
    expect((await store.outbox()).map((e) => e['card_id']), [1]);
    expect(controller.state.pendingSync, 1);
    // The rating made during the hung send did not start a second wait.
    expect(attempts, 1);

    // Rating works again straight away.
    controller.flip();
    await controller.rate(Rating.good);
    expect(controller.state.current?.id, 3);
    hung.complete();
  });

  test('a timed-out send is replayed once, never applied twice', () async {
    final (controller, api, store, hung) = await onlineSessionWithHungSend(2);

    controller.flip();
    await controller.rate(Rating.good);
    controller.flip();
    await controller.rate(Rating.good);
    await controller.undo().timeout(guard, onTimeout: () => fail('hung'));
    expect((await store.outbox()).map((e) => e['card_id']), [1]);

    // The abandoned request reaches the server after all.
    api.beforeApplyReview = null;
    hung.complete();
    await waitFor(() => api.applied.length == 1);

    // The replay is acknowledged by the server's existing log row.
    await controller.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(controller.state.pendingSync, 0);
    expect(
      api.server.reviewLog.where((row) => row['card_id'] == 1),
      hasLength(1),
    );
    expect(api.applied.map((e) => e['card_id']), [1]);
  });

  test('Keep going settles after a hung send instead of spinning', () async {
    final (controller, api, store, hung) = await onlineSessionWithHungSend(1);

    controller.flip();
    await controller.rate(Rating.good);
    expect(controller.state.isDone, isTrue);

    await controller.keepGoing().timeout(
      guard,
      onTimeout: () => fail('Keep going waited on a send that never returns'),
    );

    expect(controller.state.loading, isFalse);
    // Undelivered: the done screen explains bonus cards need a connection.
    expect(controller.state.offline, isTrue);
    expect((await store.outbox()).map((e) => e['card_id']), [1]);
    hung.complete();
  });

  test('sign-out during a hung send refuses and keeps the review', () async {
    final (controller, api, store, hung) = await onlineSessionWithHungSend(2);

    controller.flip();
    await controller.rate(Rating.good);

    final signingOut = controller.signOut().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    expect(
      await signingOut.timeout(
        guard,
        onTimeout: () => fail('Sign-out waited on a send that never returns'),
      ),
      isA<PendingSyncException>(),
    );
    expect(api.signedOut, isFalse);
    expect((await store.outbox()).map((e) => e['card_id']), [1]);
    hung.complete();
  });

  test('a send that answers within the bound still delivers', () async {
    final (controller, api, store, hung) = await onlineSessionWithHungSend(2);
    api.beforeApplyReview = null;

    controller.flip();
    await controller.rate(Rating.good);
    await waitFor(() => api.applied.length == 1);
    await waitFor(() => controller.state.pendingSync == 0);
    expect(await store.outbox(), isEmpty);
    expect(controller.state.offline, isFalse);
    hung.complete();
  });
}

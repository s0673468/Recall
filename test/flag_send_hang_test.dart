import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/core/background/browser_foreground_sync_coordinator.dart';
import 'package:health_anki_flutter/core/background/browser_sync_platform.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

class _VisibleBrowser implements BrowserSyncPlatform {
  void Function()? wake;

  @override
  bool get supported => true;
  @override
  bool get visible => true;
  @override
  bool get online => true;
  @override
  void start(void Function() onWake) => wake = onWake;
  @override
  void dispose() {}
}

// The flag counterpart of review_send_timeout_test.dart. A flag or hide send
// on a dead connection can stay open for minutes. Undo of a hide, sign-out and
// every syncPending caller (the web's 1-minute timer, Android's reconnect and
// resume) wait for the flag flush, so one hung flag send must not freeze them.
// The send itself is never abandoned: a withdrawal must not overtake it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bound = Duration(milliseconds: 50);
  // Far longer than [bound]; only a wait that is never bounded hits it.
  const guard = Duration(seconds: 5);

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 1000 && !condition(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(condition(), isTrue);
  }

  Future<(ReviewController, FakeRecallApi, LocalReviewStore)> onlineSession(
    int cards,
  ) async {
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
    return (controller, api, store);
  }

  test('Undo of a hide during a hung flag send returns after the bound, '
      'and its withdrawal goes out only after that send', () async {
    final (controller, api, store) = await onlineSession(3);
    final hung = Completer<void>();
    var sends = 0;
    api.beforeApplyFlag = () {
      sends++;
      return hung.future;
    };
    int? appliedWhenDismissed;
    api.beforeDismissFlag = () async {
      appliedWhenDismissed = api.flagged.length;
    };

    await controller.hideCurrent('delete'); // its send hangs
    await waitFor(() => sends == 1);
    expect(controller.state.current?.id, 2);
    expect(controller.canUndo, isTrue);

    await controller.undo().timeout(
      guard,
      onTimeout: () => fail('Undo waited on a flag send that never returns'),
    );

    expect(controller.undoInFlight, isFalse);
    expect(controller.state.current?.id, 1);
    // The withdrawal is queued behind the running send, not sent beside it.
    expect(api.dismissedFlags, isEmpty);
    final queued = await store.flagOutbox();
    expect(queued.map((e) => e['op']), [ReviewController.dismissOp]);
    expect(queued.single['card_id'], 1);

    // Rating works again straight away.
    controller.flip();
    await controller.rate(Rating.good);
    expect(controller.state.current?.id, 2);

    // The abandoned send lands after all; only then is it withdrawn.
    api.beforeApplyFlag = null;
    hung.complete();
    await waitFor(() => api.dismissedFlags.length == 1);
    expect(api.flagged.single['reason'], 'delete');
    expect(appliedWhenDismissed, 1);
    expect(await store.flagOutbox(), isEmpty);
    expect(await api.fetchHiddenCardIds(), isEmpty);
  });

  test('Undo of a hide whose withdrawal hangs restores the card and queues '
      'the withdrawal', () async {
    final (controller, api, store) = await onlineSession(2);
    await controller.hideCurrent('dislike');
    await waitFor(() => api.flagged.length == 1);
    await controller.syncPending();
    expect(await store.flagOutbox(), isEmpty);

    final hung = Completer<void>();
    api.beforeDismissFlag = () => hung.future;

    await controller.undo().timeout(
      guard,
      onTimeout: () => fail('Undo waited on a withdrawal that never returns'),
    );

    expect(controller.undoInFlight, isFalse);
    expect(controller.state.current?.id, 1);
    final queued = await store.flagOutbox();
    expect(queued.map((e) => e['op']), [ReviewController.dismissOp]);

    // The abandoned withdrawal and its replay are the same conditional
    // update, so both landing is harmless.
    api.beforeDismissFlag = null;
    hung.complete();
    await controller.syncPending();
    expect(await store.flagOutbox(), isEmpty);
    expect(await api.fetchHiddenCardIds(), isEmpty);
  });

  test('sign-out during a hung flag send refuses and keeps the flag', () async {
    final (controller, api, store) = await onlineSession(2);
    final hung = Completer<void>();
    api.beforeApplyFlag = () => hung.future;

    await controller.flag('wrong');

    final signingOut = controller.signOut().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    final error = await signingOut.timeout(
      guard,
      onTimeout: () => fail('Sign-out waited on a hung flag send'),
    );
    expect(error, isA<PendingSyncException>());
    expect((error as PendingSyncException).pendingFlags, 1);
    expect(api.signedOut, isFalse);
    expect((await store.flagOutbox()).single['reason'], 'wrong');
    hung.complete();
  });

  test("a hung flag send no longer stalls the web timer's review retry", () async {
    final (controller, api, store) = await onlineSession(3);
    final hung = Completer<void>();
    api.beforeApplyFlag = () => hung.future;
    await controller.flag('confusing'); // its send hangs

    // The network drops: a rating stays queued.
    api.failApplyReview = true;
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending().timeout(
      guard,
      onTimeout: () => fail('syncPending waited on a hung flag send'),
    );
    expect((await store.outbox()).map((e) => e['card_id']), [1]);

    final browser = _VisibleBrowser();
    final sync = BrowserForegroundSyncCoordinator(
      platform: browser,
      hasSession: () => true,
      syncPending: controller.syncPending,
      refreshIfIdle: () async {},
      interval: const Duration(hours: 1),
    )..start();
    addTearDown(sync.dispose);

    // A tick on the still-dead network, then the connection returns.
    browser.wake!();
    await Future<void>.delayed(bound * 3);
    api.failApplyReview = false;
    await sync.sync().timeout(
      guard,
      onTimeout: () => fail('the web sync loop waited on a hung flag send'),
    );

    expect(await store.outbox(), isEmpty);
    expect(api.applied.map((e) => e['card_id']), [1]);
    // The flag stays queued until its own send settles.
    expect((await store.flagOutbox()).single['reason'], 'confusing');
    hung.complete();
  });

  test('a flag send that answers within the bound still delivers', () async {
    final (controller, api, store) = await onlineSession(2);
    await controller.hideCurrent('dislike');
    await controller.syncPending();
    expect(api.flagged.single['reason'], 'dislike');

    await controller.undo();
    expect(controller.state.current?.id, 1);
    // The direct withdrawal answered, so nothing is left queued.
    expect(api.dismissedFlags, hasLength(1));
    expect(await store.flagOutbox(), isEmpty);

    await controller.flag('wrong');
    await controller.signOut();
    expect(api.signedOut, isTrue);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_test_harness.dart';

// A network can drop in the middle of an online session without the app being
// told: a dead zone where the phone still looks connected. A failed review send
// is the first evidence of it. Until a delivery proves the server reachable
// again, later ratings must stay local (undoable at once, labelled "Offline")
// instead of each starting another doomed send that Undo has to wait out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bound = Duration(milliseconds: 50);

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 1000 && !condition(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(condition(), isTrue);
  }

  Future<(ReviewController, FakeRecallApi, LocalReviewStore)> onlineSession(
    int cards, {
    FakeRecallApi? fake,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final api =
        fake ??
        FakeRecallApi([for (var id = 1; id <= cards; id++) testCard(id: id)]);
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

  test('a failed send marks the session offline and keeps later '
      'ratings local and undoable', () async {
    final (controller, api, store) = await onlineSession(3);
    var attempts = 0;
    var flushes = 0;
    api.beforeApplyReview = () async {
      attempts++;
      throw StateError('connection reset');
    };

    controller.flip();
    await controller.rate(Rating.good); // its send fails: no signal
    await waitFor(() => attempts == 1);
    await controller.syncPending(); // join the failed pass
    flushes = attempts;

    expect(controller.state.offline, isTrue);
    expect(controller.state.serverError, isFalse);
    expect(controller.state.pendingSync, 1);

    controller.flip();
    await controller.rate(Rating.again); // a mis-tap, still in the dead zone
    await Future<void>.delayed(bound * 2);
    // No new send was started for it.
    expect(attempts, flushes);
    expect(controller.canUndo, isTrue);

    await controller.undo();
    expect(controller.state.current?.id, 2);
    expect(controller.flagNotice, isNull);
    expect((await store.outbox()).map((e) => e['card_id']), [1]);

    // The signal returns; the next sync delivers and clears offline.
    api.beforeApplyReview = null;
    await controller.syncPending();
    expect(api.applied.map((e) => e['card_id']), [1]);
    expect(await store.outbox(), isEmpty);
    expect(controller.state.offline, isFalse);
  });

  test('a hung send marks the session offline after the bound', () async {
    final (controller, api, store) = await onlineSession(3);
    final hung = Completer<void>();
    var attempts = 0;
    api.beforeApplyReview = () {
      attempts++;
      return hung.future;
    };

    controller.flip();
    await controller.rate(Rating.good);
    await waitFor(() => attempts == 1);
    await controller.syncPending(); // returns once the bound gives up

    expect(controller.state.offline, isTrue);

    controller.flip();
    await controller.rate(Rating.good);
    await Future<void>.delayed(bound * 2);
    expect(attempts, 1);
    expect(controller.canUndo, isTrue);
    // Undo has no running send to wait for.
    expect(controller.undoInFlight, isFalse);
    await controller.undo();
    expect(controller.state.current?.id, 2);
    expect(controller.flagNotice, isNull);
    hung.complete();
  });

  test('a server error during a send is labelled, then cleared on '
      'reconnect', () async {
    final (controller, api, store) = await onlineSession(2);
    api.beforeApplyReview = () async =>
        throw const PostgrestException(message: 'upstream', code: '503');

    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();

    expect(controller.state.offline, isTrue);
    expect(controller.state.serverError, isTrue);
    expect(controller.state.pendingSync, 1);
    expect(controller.state.syncErrors, 0); // retryable, not parked

    api.beforeApplyReview = null;
    await controller.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(controller.state.offline, isFalse);
    expect(controller.state.serverError, isFalse);
  });

  test('a transport failure after a server error is labelled offline, '
      'not "Server error"', () async {
    final (controller, api, store) = await onlineSession(3);
    api.beforeApplyReview = () async =>
        throw const PostgrestException(message: 'upstream', code: '503');
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();
    expect(controller.state.serverError, isTrue);

    api.beforeApplyReview = () async => throw StateError('no route to host');
    await controller.syncPending();
    expect(controller.state.offline, isTrue);
    expect(controller.state.serverError, isFalse);
  });

  test('a local outbox failure is not taken as a network failure', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
    final store = _AttemptFailingStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      reviewSendTimeout: bound,
    );
    addTearDown(controller.dispose);
    await controller.load();
    store.failMark = true;

    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();

    expect(api.applied, isEmpty);
    expect(controller.state.offline, isFalse);
  });

  test('Keep going labels a server error from its fetch', () async {
    final api = _AheadFailingApi([testCard(id: 1)]);
    final (controller, _, _) = await onlineSession(1, fake: api);
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();
    expect(controller.state.isDone, isTrue);

    api.aheadError = const PostgrestException(message: 'boom', code: '500');
    await controller.keepGoing();
    expect(controller.state.offline, isTrue);
    expect(controller.state.serverError, isTrue);

    api.aheadError = StateError('offline');
    await controller.keepGoing();
    expect(controller.state.offline, isTrue);
    expect(controller.state.serverError, isFalse);
  });

  test('a drop after a delivery in the same pass waits for the next '
      'pass before going offline', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeRecallApi([
      for (var id = 1; id <= 4; id++) testCard(id: id),
    ]);
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      reviewSendTimeout: bound,
    );
    addTearDown(controller.dispose);
    // Two ratings queued while offline, so one pass carries both.
    await controller.load(); // persist a snapshot to study from
    api.beforeQueue = () async => throw StateError('offline');
    await controller.refresh();
    expect(controller.state.offline, isTrue);
    api.beforeQueue = null;
    controller.flip();
    await controller.rate(Rating.good);
    controller.flip();
    await controller.rate(Rating.good);

    var sends = 0;
    api.beforeApplyReview = () async {
      if (++sends > 1) throw StateError('connection reset');
    };
    await controller.syncPending();
    // The first delivery proves the server reachable (#137).
    expect(api.applied.map((e) => e['card_id']), [1]);
    expect(controller.state.offline, isFalse);

    // The next pass delivers nothing: now the drop is believed.
    await controller.syncPending();
    expect(controller.state.offline, isTrue);
    expect(controller.state.serverError, isFalse);
    expect(controller.state.pendingSync, 1);
  });

  test('a send that succeeds keeps the session online', () async {
    final (controller, api, store) = await onlineSession(3);

    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();

    expect(api.applied.map((e) => e['card_id']), [1, 2]);
    expect(controller.state.offline, isFalse);
    expect(controller.state.serverError, isFalse);
  });
}

class _AheadFailingApi extends FakeRecallApi {
  _AheadFailingApi(super.cards);

  Object? aheadError;

  @override
  Future<List<ReviewCard>> fetchAheadQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    Duration horizon = const Duration(hours: 24),
    int limit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    final error = aheadError;
    if (error != null) throw error;
    return super.fetchAheadQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      horizon: horizon,
      limit: limit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
  }
}

class _AttemptFailingStore extends LocalReviewStore {
  bool failMark = false;

  @override
  Future<bool> markReviewAttempted(Object clientId, {String? ownerScope}) {
    if (failMark) throw StateError('disk full');
    return super.markReviewAttempted(clientId, ownerScope: ownerScope);
  }
}

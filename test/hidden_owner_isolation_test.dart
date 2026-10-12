import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_acceptance_fixture.dart';

// Invented users/cards, .invalid service client and in-memory preferences only.
final _now = DateTime.utc(2026, 10, 11, 12);
const _ownerAEmail = 'hidden-a@example.invalid';
const _ownerBEmail = 'hidden-b@example.invalid';

ReviewCard _card(int id) => ReviewCard(
  id: id,
  guid: 'invented-hidden-$id',
  deckId: 1,
  front: 'Invented front $id',
  back: 'Invented back $id',
  hasLatex: false,
  stability: 4,
  difficulty: 5,
  due: _now.subtract(const Duration(days: 1)),
  state: 2,
  reps: 3,
  lapses: 0,
  lastReview: _now.subtract(const Duration(days: 5)),
  cloudSeen: true,
);

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> hold() async {
    entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

class _Api extends SanitizedRecallApi {
  final hiddenByOwner = <String, Set<int>>{};
  _Gate? nextHiddenRead;
  _Gate? nextDismiss;
  bool failHiddenRead = false;
  bool failFlagWrite = false;
  Set<int> lastAheadExcludedIds = const {};

  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [_card(101), _card(201), _card(202)],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.signedOut,
      );

  Set<int> get hidden => hiddenByOwner.putIfAbsent(currentUser!.id, () => {});

  @override
  Future<Set<int>> fetchHiddenCardIds() async {
    final result = {...hidden};
    final fail = failHiddenRead;
    final gate = nextHiddenRead;
    nextHiddenRead = null;
    if (gate != null) await gate.hold();
    if (fail) throw StateError('invented hidden-card transport failure');
    return result;
  }

  @override
  Future<List<ReviewCard>> fetchAheadQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    Duration horizon = const Duration(hours: 24),
    int limit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) {
    lastAheadExcludedIds = {...excludeCardIds};
    return super.fetchAheadQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      horizon: horizon,
      limit: limit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    if (failFlagWrite) throw StateError('invented flag transport failure');
    if (ReviewController.hideReasons.contains(entry['reason'])) {
      hidden.add((entry['card_id'] as num).toInt());
    }
  }

  @override
  Future<void> dismissFlag({
    required int cardId,
    required String clientEventId,
  }) async {
    final ids = hidden;
    final gate = nextDismiss;
    nextDismiss = null;
    if (gate != null) await gate.hold();
    ids.remove(cardId);
  }
}

class _Store extends LocalReviewStore {
  _Gate? nextHiddenRead;

  @override
  Future<Set<int>> hiddenCardIds() async {
    final gate = nextHiddenRead;
    nextHiddenRead = null;
    final result = await super.hiddenCardIds();
    if (gate != null) await gate.hold();
    return result;
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Invented hidden-card session did not settle');
}

Future<({ReviewController controller, _Api api, _Store store})>
_session() async {
  final api = _Api();
  final store = _Store();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
    clock: () => _now,
    beforeSessionLoad: () => store.activateOwner(api.currentUser!.id),
  );
  addTearDown(() {
    controller.dispose();
    api.disposeFixture();
  });
  await api.signIn(email: _ownerAEmail, password: 'invented-password');
  await _until(
    () =>
        store.isActiveOwner(api.currentUser!.id) &&
        !controller.state.loading &&
        controller.state.current != null,
  );
  return (controller: controller, api: api, store: store);
}

Future<void> _switchOwner(
  ReviewController controller,
  _Api api,
  _Store store,
) async {
  await api.signIn(email: _ownerBEmail, password: 'invented-password');
  api.hidden.add(202);
  await _until(
    () => store.isActiveOwner(api.currentUser!.id) && !controller.state.loading,
  );
  expect(await store.hiddenCardIds(), {202});
  expect(controller.state.queue.map((card) => card.id), [101, 201]);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'late A cached hidden read cannot replace B in-memory exclusions',
    () async {
      final (:controller, :api, :store) = await _session();
      await store.replaceHiddenCards({201});
      final gate = _Gate();
      addTearDown(gate.open);
      store.nextHiddenRead = gate;
      final stale = controller.load();
      await gate.entered.future;
      await _switchOwner(controller, api, store);
      gate.open();
      await stale;

      await controller.keepGoing();
      expect(api.lastAheadExcludedIds, {202});
      expect(await store.hiddenCardIds(), {202});
    },
  );

  test('late A server hidden read cannot contaminate B namespace', () async {
    final (:controller, :api, :store) = await _session();
    api.hidden.add(201);
    final gate = _Gate();
    addTearDown(gate.open);
    api.nextHiddenRead = gate;
    final stale = controller.refresh();
    await gate.entered.future;
    await _switchOwner(controller, api, store);
    gate.open();
    await stale;

    expect(await store.hiddenCardIds(), {202});
    await controller.keepGoing();
    expect(api.lastAheadExcludedIds, {202});
  });

  test('late A failed server read cannot apply A pending hide to B', () async {
    final (:controller, :api, :store) = await _session();
    api.failFlagWrite = true;
    await store.enqueueFlag({
      'card_id': 201,
      'reason': 'dislike',
      'client_id': 'invented-pending-hide',
    });
    final gate = _Gate();
    addTearDown(gate.open);
    api
      ..failHiddenRead = true
      ..nextHiddenRead = gate;
    final stale = controller.refresh();
    await gate.entered.future;
    api.failHiddenRead = false;
    await _switchOwner(controller, api, store);
    gate.open();
    await stale;

    expect(await store.hiddenCardIds(), {202});
    await controller.keepGoing();
    expect(api.lastAheadExcludedIds, {202});
  });

  test(
    'superseded same-owner refresh cannot replace newer hidden truth',
    () async {
      final (:controller, :api, :store) = await _session();
      api.hidden.add(201);
      final gate = _Gate();
      addTearDown(gate.open);
      api.nextHiddenRead = gate;
      final stale = controller.refresh();
      await gate.entered.future;
      api.hidden
        ..clear()
        ..add(202);
      await controller.refresh();
      expect(await store.hiddenCardIds(), {202});
      gate.open();
      await stale;

      expect(await store.hiddenCardIds(), {202});
      await controller.keepGoing();
      expect(api.lastAheadExcludedIds, {202});
    },
  );

  test(
    'same-owner hide during server read wins over stale server truth',
    () async {
      final (:controller, :api, :store) = await _session();
      api.failFlagWrite = true;
      final gate = _Gate();
      addTearDown(gate.open);
      api.nextHiddenRead = gate;
      final refresh = controller.refresh();
      await gate.entered.future;
      await controller.hideCurrent('dislike');
      gate.open();
      await refresh;

      expect(await store.hiddenCardIds(), {101});
      expect(controller.state.current?.id, 201);
      expect(
        controller.state.queue.skip(controller.state.index).map((c) => c.id),
        isNot(contains(101)),
      );
      expect((await store.flagOutbox()).single['card_id'], 101);
    },
  );

  test(
    'same-owner unhide during server read wins over stale server truth',
    () async {
      final (:controller, :api, :store) = await _session();
      await controller.hideCurrent('dislike');
      await controller.syncPending();
      expect(await store.hiddenCardIds(), {101});
      final dismissGate = _Gate();
      final readGate = _Gate();
      addTearDown(dismissGate.open);
      addTearDown(readGate.open);
      api.nextDismiss = dismissGate;
      final undo = controller.undo();
      await dismissGate.entered.future;
      api.nextHiddenRead = readGate;
      final refresh = controller.refresh();
      await readGate.entered.future;
      dismissGate.open();
      await undo;
      readGate.open();
      await refresh;

      expect(await store.hiddenCardIds(), isEmpty);
      expect(controller.state.queue.map((card) => card.id), [101, 201, 202]);
      expect(controller.state.index, 0);
      expect(controller.canUndo, isFalse);
    },
  );

  test(
    'queued hidden replacement cancels inside lock after owner activation',
    () async {
      final store = LocalReviewStore();
      await store.activateOwner(_ownerAEmail);
      await store.replaceHiddenCards({101});
      final ownerA = store.activeOwnerScope!;
      await store.activateOwner(_ownerBEmail);
      await store.replaceHiddenCards({202});
      await store.activateOwner(_ownerAEmail);

      // Both operations queue while A is still active. B activates first;
      // cancellation must be checked when the replacement acquires the lock.
      final switchOwner = store.activateOwner(_ownerBEmail);
      final replacement = store.replaceHiddenCards(
        {201},
        ownerScope: ownerA,
        canWrite: () => store.activeOwnerScope == ownerA,
      );
      await switchOwner;
      await replacement;

      expect(await store.hiddenCardIds(), {202});
      await store.activateOwner(_ownerAEmail);
      expect(await store.hiddenCardIds(), {101});
    },
  );

  test(
    'explicit original-owner replacement writes only that namespace',
    () async {
      final store = LocalReviewStore();
      await store.activateOwner(_ownerAEmail);
      final ownerA = store.activeOwnerScope!;
      await store.activateOwner(_ownerBEmail);
      await store.replaceHiddenCards({202});

      await store.replaceHiddenCards({201}, ownerScope: ownerA);

      expect(await store.hiddenCardIds(), {202});
      await store.activateOwner(_ownerAEmail);
      expect(await store.hiddenCardIds(), {201});
    },
  );

  test(
    'late cached hidden read stays cancelled after sign-out and B sign-in',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = api.currentUser!.id;
      await store.replaceHiddenCards({201});
      final gate = _Gate();
      addTearDown(gate.open);
      store.nextHiddenRead = gate;
      final stale = controller.load();
      await gate.entered.future;

      await controller.signOut();
      expect(api.currentUser, isNull);
      await _switchOwner(controller, api, store);
      gate.open();
      await stale;

      await controller.keepGoing();
      expect(api.lastAheadExcludedIds, {202});
      expect(await store.hiddenCardIds(), {202});
      await store.activateOwner(ownerA);
      expect(await store.hiddenCardIds(), isEmpty);
    },
  );

  test(
    'late server hidden read stays cancelled after sign-out and B sign-in',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = api.currentUser!.id;
      api.hidden.add(201);
      final gate = _Gate();
      addTearDown(gate.open);
      api.nextHiddenRead = gate;
      final stale = controller.refresh();
      await gate.entered.future;

      await controller.signOut();
      expect(api.currentUser, isNull);
      await _switchOwner(controller, api, store);
      gate.open();
      await stale;

      await controller.keepGoing();
      expect(api.lastAheadExcludedIds, {202});
      expect(await store.hiddenCardIds(), {202});
      await store.activateOwner(ownerA);
      expect(await store.hiddenCardIds(), isEmpty);
    },
  );

  test(
    'refused sign-out preserves a delayed hidden read and pending hide',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = api.currentUser!.id;
      final scopeA = store.activeOwnerScope;
      api.failFlagWrite = true;
      await store.enqueueFlag({
        'card_id': 201,
        'reason': 'dislike',
        'client_id': 'invented-hidden-signout-refusal',
      });
      final gate = _Gate();
      addTearDown(gate.open);
      api.nextHiddenRead = gate;
      final stale = controller.refresh();
      await gate.entered.future;

      await expectLater(
        controller.signOut(),
        throwsA(isA<PendingSyncException>()),
      );
      expect(api.currentUser?.id, ownerA);
      expect(store.activeOwnerScope, scopeA);
      gate.open();
      await stale;

      expect(await store.hiddenCardIds(), {201});
      expect((await store.flagOutbox()).single['card_id'], 201);
      await controller.keepGoing();
      expect(api.lastAheadExcludedIds, {201});
    },
  );
}

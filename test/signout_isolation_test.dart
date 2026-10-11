import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_acceptance_fixture.dart';

// All records and transport outcomes are invented. Preferences are in-memory;
// the adapter overrides service operations and never loads production config.
final _now = DateTime.utc(2026, 10, 11, 12);

ReviewCard _card(int id) => ReviewCard(
  id: id,
  guid: 'invented-signout-$id',
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
  int signOutCalls = 0;
  bool failWrites = true;
  bool failSignOut = false;
  bool failDismiss = true;
  final reviewAttempts = <String>[];
  final flagAttempts = <String>[];

  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [_card(101), _card(102), _card(103)],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    reviewAttempts.add(entry['client_id'].toString());
    if (failWrites) throw StateError('invented lost acknowledgement');
    return super.applyReview(entry);
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    flagAttempts.add(entry['client_id'].toString());
    if (failWrites) throw StateError('invented offline flag');
    await super.applyFlag(entry);
  }

  @override
  Future<void> dismissFlag({
    required int cardId,
    required String clientEventId,
  }) async {
    if (failDismiss) throw StateError('invented offline withdrawal');
    await super.dismissFlag(cardId: cardId, clientEventId: clientEventId);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (failSignOut) throw StateError('invented auth sign-out failure');
    await super.signOut();
  }
}

class _Store extends LocalReviewStore {
  _Gate? nextId;
  _Gate? beforeClear;
  _Gate? beforeWithdrawal;
  String? lastMintedId;
  bool failNextId = false;

  @override
  Future<String> newEventId() async {
    final gate = nextId;
    nextId = null;
    if (gate != null) await gate.hold();
    if (failNextId) {
      failNextId = false;
      throw StateError('invented ID persistence failure');
    }
    return lastMintedId = await super.newEventId();
  }

  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) async {
    if (entry['op'] == ReviewController.dismissOp) {
      final gate = beforeWithdrawal;
      beforeWithdrawal = null;
      if (gate != null) await gate.hold();
    }
    return super.enqueueFlag(entry);
  }

  @override
  Future<void> clear({
    String? ownerScope,
    bool requireEmptyOutboxes = false,
    bool Function()? canClear,
  }) async {
    final gate = beforeClear;
    beforeClear = null;
    if (gate != null) await gate.hold();
    await super.clear(
      ownerScope: ownerScope,
      requireEmptyOutboxes: requireEmptyOutboxes,
      canClear: canClear,
    );
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Invented session did not settle');
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
  await api.signIn(
    email: 'synthetic-signout-a@example.invalid',
    password: 'invented-password',
  );
  await _until(
    () => !controller.state.loading && controller.state.current != null,
  );
  expect(controller.state.current?.id, 101);
  return (controller: controller, api: api, store: store);
}

Future<Object?> _outcome(Future<void> action) async {
  try {
    await action;
    return null;
  } catch (error) {
    return error;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'fresh actions between empty check and clear survive sign-out',
    () async {
      final (:controller, :api, :store) = await _session();
      final gate = _Gate();
      addTearDown(gate.open);
      store.beforeClear = gate;
      final ownerA = store.activeOwnerScope!;
      final signingOut = _outcome(controller.signOut());
      await gate.entered.future;
      await store.enqueueReview({
        'card_id': 101,
        'client_id': 'invented-late-review',
        'delivery_attempted': true,
      }, ownerScope: ownerA);
      await store.enqueueFlag({
        'card_id': 102,
        'client_id': 'invented-late-flag',
        'reason': 'wrong',
      });
      gate.open();
      expect(await signingOut, isA<PendingSyncException>());
      expect(api.signOutCalls, 0);
      final review = (await store.outbox(ownerScope: ownerA)).single;
      expect(review['client_id'], 'invented-late-review');
      expect(review['delivery_attempted'], isTrue);
      expect(
        (await store.flagOutbox(ownerScope: ownerA)).single['client_id'],
        'invented-late-flag',
      );
      expect(api.currentUser, isNotNull);
    },
  );

  for (final producer in ['rating', 'flag', 'hide']) {
    test('sign-out joins $producer suspended while minting its ID', () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = store.activeOwnerScope!;
      final gate = _Gate();
      addTearDown(gate.open);
      store.nextId = gate;
      controller.flip();
      final action = switch (producer) {
        'rating' => controller.rate(Rating.good),
        'flag' => controller.flag('wrong'),
        _ => controller.hideCurrent('dislike'),
      };
      await gate.entered.future;
      final signingOut = _outcome(controller.signOut());
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.signOutCalls, 0);
      gate.open();
      await action;
      expect(await signingOut, isA<PendingSyncException>());
      final pending = producer == 'rating'
          ? await store.outbox(ownerScope: ownerA)
          : await store.flagOutbox(ownerScope: ownerA);
      expect(pending.single['client_id'], store.lastMintedId);
      expect(pending.single['card_id'], 101);
      expect(api.currentUser, isNotNull);
    });
  }

  test('sign-out joins an admitted hide Undo withdrawal producer', () async {
    final (:controller, :api, :store) = await _session();
    await controller.hideCurrent('dislike');
    await controller.syncPending();
    final hiddenId = (await store.flagOutbox()).single['client_id'];
    final gate = _Gate();
    addTearDown(gate.open);
    store.beforeWithdrawal = gate;
    final undoing = controller.undo();
    await gate.entered.future;
    final signingOut = _outcome(controller.signOut());
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.signOutCalls, 0);
    gate.open();
    await undoing;
    expect(await signingOut, isA<PendingSyncException>());
    final pending = (await store.flagOutbox()).single;
    expect(pending['client_id'], hiddenId);
    expect(pending['op'], ReviewController.dismissOp);
  });

  test(
    'closed ingress rejects new actions and reopens after pending failure',
    () async {
      final (:controller, :api, :store) = await _session();
      final gate = _Gate();
      addTearDown(gate.open);
      store.beforeClear = gate;
      controller.flip();
      final signingOut = _outcome(controller.signOut());
      await gate.entered.future;
      await controller.rate(Rating.good);
      await controller.flag('wrong');
      await controller.hideCurrent('dislike');
      await controller.undo();
      expect(controller.state.current?.id, 101);
      expect(controller.state.showBack, isTrue);
      expect(await store.outbox(), isEmpty);
      expect(await store.flagOutbox(), isEmpty);
      await store.enqueueFlag({
        'card_id': 103,
        'client_id': 'invented-block-signout',
        'reason': 'wrong',
      });
      gate.open();
      expect(await signingOut, isA<PendingSyncException>());
      await controller.rate(Rating.good);
      expect(controller.state.current?.id, 102);
      expect((await store.outbox()).single['card_id'], 101);
      expect(api.signOutCalls, 0);
      await controller.syncPending();
    },
  );

  test(
    'successful sign-out drains admitted rating and keeps device ID',
    () async {
      final (:controller, :api, :store) = await _session();
      api.failWrites = false;
      final installId = await store.installId();
      final ownerA = store.activeOwnerScope!;
      final gate = _Gate();
      addTearDown(gate.open);
      store.nextId = gate;
      controller.flip();
      final rating = controller.rate(Rating.good);
      await gate.entered.future;
      final first = controller.signOut();
      final second = controller.signOut();
      gate.open();
      await rating;
      await Future.wait([first, second]);
      expect(api.signOutCalls, 1);
      expect(api.reviewAttempts, [store.lastMintedId]);
      expect(await store.outbox(ownerScope: ownerA), isEmpty);
      expect(await store.flagOutbox(ownerScope: ownerA), isEmpty);
      expect(await store.installId(), installId);
      expect(api.currentUser, isNull);
    },
  );

  test(
    'owner replacement before clear preserves both owner namespaces',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = store.activeOwnerScope!;
      final gate = _Gate();
      addTearDown(gate.open);
      store.beforeClear = gate;
      final signingOut = _outcome(controller.signOut());
      await gate.entered.future;
      await api.signIn(
        email: 'synthetic-signout-b@example.invalid',
        password: 'invented-password',
      );
      await _until(() => store.isActiveOwner(api.currentUser!.id));
      final ownerB = store.activeOwnerScope!;
      await store.enqueueReview({
        'card_id': 102,
        'client_id': 'invented-owner-b',
      }, ownerScope: ownerB);
      gate.open();
      expect(await signingOut, isA<StateError>());
      expect(api.signOutCalls, 0);
      expect(
        (await store.outbox(ownerScope: ownerB)).single['client_id'],
        'invented-owner-b',
      );
      expect(await store.outbox(ownerScope: ownerA), isEmpty);
      await controller.syncPending();
    },
  );

  test(
    'empty-only clear observes a write queued before its lock entry',
    () async {
      final store = _Store();
      await store.activateOwner('invented-lock-owner');
      final owner = store.activeOwnerScope!;
      final enqueue = store.enqueueReview({
        'card_id': 101,
        'client_id': 'invented-lock-review',
        'delivery_attempted': true,
      }, ownerScope: owner);
      final clearing = _outcome(
        store.clear(ownerScope: owner, requireEmptyOutboxes: true),
      );
      await enqueue;
      final error = await clearing;
      expect(error, isA<LocalOutboxNotEmptyException>());
      expect((error as LocalOutboxNotEmptyException).pendingReviews, 1);
      expect(error.pendingFlags, 0);
      final retained = (await store.outbox(ownerScope: owner)).single;
      expect(retained['client_id'], 'invented-lock-review');
      expect(retained['delivery_attempted'], isTrue);
    },
  );

  test('producer failure aborts sign-out and reopens ingress', () async {
    final (:controller, :api, :store) = await _session();
    final gate = _Gate();
    addTearDown(gate.open);
    store.nextId = gate;
    store.failNextId = true;
    controller.flip();
    final rating = _outcome(controller.rate(Rating.good));
    await gate.entered.future;
    final signingOut = _outcome(controller.signOut());
    gate.open();
    expect(await rating, isA<StateError>());
    expect(await signingOut, isA<StateError>());
    expect(api.signOutCalls, 0);
    expect(await store.loadSnapshot(), isNotNull);
    expect(controller.state.current?.id, 101);
    await controller.rate(Rating.good);
    expect(controller.state.current?.id, 102);
    await controller.syncPending();
  });

  test(
    'reentrant sign-out joins an action before its first notification',
    () async {
      final (:controller, :api, :store) = await _session();
      final gate = _Gate();
      addTearDown(gate.open);
      store.nextId = gate;
      Future<Object?>? signingOut;
      void signOutOnAdmission() {
        if (controller.rateInFlight && signingOut == null) {
          signingOut = _outcome(controller.signOut());
        }
      }

      controller.addListener(signOutOnAdmission);
      addTearDown(() => controller.removeListener(signOutOnAdmission));
      controller.flip();
      final rating = controller.rate(Rating.good);
      await gate.entered.future;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.signOutCalls, 0);
      gate.open();
      await rating;
      expect(await signingOut, isA<PendingSyncException>());
      expect((await store.outbox()).single['client_id'], store.lastMintedId);
    },
  );

  test(
    'auth sign-out failure reopens action ingress in the retained session',
    () async {
      final (:controller, :api, :store) = await _session();
      api.failSignOut = true;
      expect(await _outcome(controller.signOut()), isA<StateError>());
      expect(api.currentUser, isNotNull);
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.current?.id, 102);
      expect((await store.outbox()).single['card_id'], 101);
      await controller.syncPending();
    },
  );

  test('malformed outbox prevents guarded cache removal', () async {
    SharedPreferences.setMockInitialValues({
      'recall_outbox_v1': 'invented malformed JSON',
      'recall_snapshot_v1': 'invented cache marker',
    });
    final store = LocalReviewStore();
    expect(
      await _outcome(store.clear(requireEmptyOutboxes: true)),
      isA<LocalOutboxCorruptException>(),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('recall_outbox_v1'), 'invented malformed JSON');
    expect(prefs.getString('recall_snapshot_v1'), 'invented cache marker');
  });
}

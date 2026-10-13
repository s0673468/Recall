import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_acceptance_fixture.dart';

// Invented records only. The shared adapter overrides service reads/writes;
// its client points at .invalid and no production configuration is loaded.
final _now = DateTime.utc(2026, 10, 11, 12);
const _ownerAEmail = 'synthetic-a@example.invalid';
const _ownerBEmail = 'synthetic-b@example.invalid';

ReviewCard _card(int id, int deckId) => ReviewCard(
  id: id,
  guid: 'invented-rating-$id',
  deckId: deckId,
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

class _Api extends SanitizedRecallApi {
  final attempts = <({String? owner, int cardId})>[];

  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Math'),
          ],
          cards: [_card(101, 1), _card(201, 2), _card(202, 2)],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    attempts.add((
      owner: currentUser?.id,
      cardId: (entry['card_id'] as num).toInt(),
    ));
    throw StateError('invented offline transport');
  }
}

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

class _Store extends LocalReviewStore {
  _Gate? nextId;
  _Gate? afterEnqueue;
  _Gate? beforeCatchUpSave;
  String? lastMintedId;

  @override
  Future<String> newEventId() async {
    final gate = nextId;
    nextId = null;
    if (gate != null) await gate.hold();
    return lastMintedId = await super.newEventId();
  }

  @override
  Future<int> enqueueReview(
    Map<String, dynamic> entry, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    final pending = await super.enqueueReview(
      entry,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
    final gate = afterEnqueue;
    afterEnqueue = null;
    if (gate != null) await gate.hold();
    return pending;
  }

  @override
  Future<void> saveCatchUpState(
    CatchUpLocalState state, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    final gate = beforeCatchUpSave;
    beforeCatchUpSave = null;
    if (gate != null) await gate.hold();
    await super.saveCatchUpState(
      state,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Invented session did not finish loading');
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
    () => !controller.state.loading && controller.state.current != null,
  );
  await controller.load(deckId: 1);
  expect(controller.state.current?.id, 101);
  return (controller: controller, api: api, store: store);
}

Future<void> _switchOwner(
  ReviewController controller,
  _Api api,
  _Store store,
) async {
  await api.signIn(email: _ownerBEmail, password: 'invented-password');
  await _until(
    () => store.isActiveOwner(api.currentUser!.id) && !controller.state.loading,
  );
  await controller.load(deckId: 2);
  expect(controller.state.current?.id, 201);
}

void _expectReplacementQueue(ReviewController controller) {
  expect(controller.state.current?.id, 201);
  expect(controller.state.index, 0);
  expect(controller.state.showBack, isFalse);
  expect(controller.canUndo, isFalse);
  expect(controller.rateInFlight, isFalse);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('deck switch during rating ID mint cancels before commit', () async {
    final (:controller, :api, :store) = await _session();
    final gate = _Gate();
    addTearDown(gate.open);
    store.nextId = gate;
    controller.flip();
    final rating = controller.rate(Rating.good);
    await gate.entered.future;
    await controller.load(deckId: 2);
    gate.open();
    await rating;
    _expectReplacementQueue(controller);
    expect(await store.outbox(), isEmpty);
    expect(api.attempts, isEmpty);
  });

  test(
    'owner switch during rating ID mint cannot queue or send as B',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = store.activeOwnerScope!;
      final gate = _Gate();
      addTearDown(gate.open);
      store.nextId = gate;
      controller.flip();
      final rating = controller.rate(Rating.good);
      await gate.entered.future;
      await _switchOwner(controller, api, store);
      gate.open();
      await rating;
      _expectReplacementQueue(controller);
      expect(await store.outbox(), isEmpty);
      expect(await store.outbox(ownerScope: ownerA), isEmpty);
      expect(api.attempts, isEmpty);
    },
  );

  test(
    'owner switch after enqueue preserves A event and leaves B untouched',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = store.activeOwnerScope!;
      final gate = _Gate();
      addTearDown(gate.open);
      store.afterEnqueue = gate;
      controller.flip();
      final rating = controller.rate(Rating.good);
      await gate.entered.future;
      final committed = (await store.outbox(ownerScope: ownerA)).single;
      expect(committed['card_id'], 101);
      expect(committed['client_id'], store.lastMintedId);
      await _switchOwner(controller, api, store);
      final replacementCatchUp = controller.state.catchUp;
      gate.open();
      await rating;
      _expectReplacementQueue(controller);
      expect(controller.state.catchUp, same(replacementCatchUp));
      expect(await store.outbox(), isEmpty);
      expect((await store.outbox(ownerScope: ownerA)).single, committed);
      expect(api.attempts, isEmpty);
    },
  );

  test(
    'deck switch after enqueue retains the durable original event',
    () async {
      final (:controller, :api, :store) = await _session();
      final gate = _Gate();
      addTearDown(gate.open);
      store.afterEnqueue = gate;
      controller.flip();
      final rating = controller.rate(Rating.good);
      await gate.entered.future;
      final committed = (await store.outbox()).single;
      await controller.load(deckId: 2);
      final replacementCatchUp = controller.state.catchUp;
      final attemptsBeforeRelease = api.attempts.length;
      gate.open();
      await rating;
      _expectReplacementQueue(controller);
      expect(controller.state.catchUp, same(replacementCatchUp));
      final retained = (await store.outbox()).single;
      expect(retained['card_id'], committed['card_id']);
      expect(retained['client_id'], committed['client_id']);
      expect(retained['rating'], committed['rating']);
      expect(api.attempts.length, attemptsBeforeRelease);
    },
  );

  test(
    'review enqueue checks cancellation after entering its write lock',
    () async {
      final store = _Store();
      await store.activateOwner('synthetic-lock-owner');
      var eligible = true;
      final enqueue = store.enqueueReview(
        {'client_id': 'invented-lock-event', 'card_id': 101},
        ownerScope: store.activeOwnerScope,
        canWrite: () => eligible,
      );
      eligible = false;
      await enqueue;
      expect(await store.outbox(), isEmpty);
    },
  );

  test(
    'owner switch during catch-up save keeps committed rating isolated',
    () async {
      final (:controller, :api, :store) = await _session();
      final ownerA = store.activeOwnerScope!;
      // Exercise a real active-plan progress write, rather than depending on
      // a redundant save of an already empty disposable catch-up state.
      await store.saveCatchUpState(
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2026-10-11',
        ),
      );
      await controller.load(deckId: 1);
      expect(controller.state.catchUp.isActive, isTrue);
      final gate = _Gate();
      addTearDown(gate.open);
      store.beforeCatchUpSave = gate;
      controller.flip();
      final rating = controller.rate(Rating.good);
      await gate.entered.future;
      final committed = (await store.outbox(ownerScope: ownerA)).single;
      await _switchOwner(controller, api, store);
      // Distinct disposable B progress proves the delayed A save is suppressed.
      final ownerBProgress = CatchUpLocalState(
        mode: CatchUpMode.active,
        dayKey: '2026-10-11',
        completedToday: 7,
      );
      await store.saveCatchUpState(ownerBProgress);
      final replacementCatchUp = controller.state.catchUp;
      gate.open();
      await rating;
      _expectReplacementQueue(controller);
      expect(controller.state.catchUp, same(replacementCatchUp));
      expect((await store.loadCatchUpState()).completedToday, 7);
      expect(await store.outbox(), isEmpty);
      expect((await store.outbox(ownerScope: ownerA)).single, committed);
      expect(api.attempts, isEmpty);
    },
  );
}

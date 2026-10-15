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
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_acceptance_fixture.dart';

// Invented records, in-memory preferences and a .invalid service adapter only.
final _now = DateTime.utc(2026, 10, 11, 12);
const _day = '2026-10-11';
const _ownerAEmail = 'undo-a@example.invalid';
const _ownerBEmail = 'undo-b@example.invalid';

ReviewCard _card(int id, int deckId) => ReviewCard(
  id: id,
  guid: 'invented-undo-$id',
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
  contentRevalidationPending: deckId == 1 && id != 103,
);

class _Api extends SanitizedRecallApi {
  bool queueOffline = false;
  final attempts = <({String? owner, int cardId})>[];
  int remoteUndos = 0;

  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Math'),
          ],
          cards: [
            _card(101, 1),
            _card(102, 1),
            _card(103, 1),
            _card(201, 2),
            _card(202, 2),
          ],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) {
    if (queueOffline) throw StateError('invented offline queue');
    return super.fetchQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      newLimit: newLimit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    attempts.add((
      owner: currentUser?.id,
      cardId: (entry['card_id'] as num).toInt(),
    ));
    throw StateError('invented offline transport');
  }

  @override
  Future<void> undoReview(Map<String, dynamic> entry) async {
    remoteUndos++;
    throw StateError('Remote Undo must stay closed');
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
  _Gate? beforeRemove;
  _Gate? afterRemove;
  _Gate? beforeCatchUpRead;
  _Gate? beforeCatchUpSave;
  int snapshots = 0;

  @override
  Future<({bool removed, int remaining})> removeEntry(
    Object clientId, {
    String? ownerScope,
  }) async {
    final before = beforeRemove;
    beforeRemove = null;
    if (before != null) await before.hold();
    final result = await super.removeEntry(clientId, ownerScope: ownerScope);
    final after = afterRemove;
    afterRemove = null;
    if (after != null) await after.hold();
    return result;
  }

  @override
  Future<CatchUpLocalState> loadCatchUpStateForOwner(String? ownerScope) async {
    final gate = beforeCatchUpRead;
    beforeCatchUpRead = null;
    if (gate != null) await gate.hold();
    return super.loadCatchUpStateForOwner(ownerScope);
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

  @override
  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
    int? deckId,
    int? globalDueCount,
    DateTime? globalDueUpdatedAt,
    bool Function()? canWrite,
  }) async {
    snapshots++;
    await super.saveSnapshot(
      decks: decks,
      queue: queue,
      deckId: deckId,
      globalDueCount: globalDueCount,
      globalDueUpdatedAt: globalDueUpdatedAt,
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

Future<
  ({ReviewController controller, _Api api, _Store store, List<String> haptics})
>
_session() async {
  final api = _Api();
  final store = _Store();
  final haptics = <String>[];
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: ReviewHaptics(onUndo: () => haptics.add('undo')),
    clock: () => _now,
    beforeSessionLoad: () => store.activateOwner(api.currentUser!.id),
    afterSignOut: store.releaseOwner,
  );
  addTearDown(() {
    controller.dispose();
    api.disposeFixture();
  });
  await api.signIn(email: _ownerAEmail, password: 'invented-password');
  await _until(
    () => !controller.state.loading && controller.state.current != null,
  );
  await store.saveCatchUpState(
    const CatchUpLocalState(
      mode: CatchUpMode.active,
      dayKey: _day,
      completedToday: 4,
    ),
  );
  await controller.load(deckId: 1);
  api.queueOffline = true;
  await controller.refresh();
  expect(controller.state.offline, isTrue);
  for (final cardId in [101, 102]) {
    expect(controller.state.current?.id, cardId);
    controller.flip();
    await controller.rate(Rating.good);
  }
  expect(controller.state.index, 2);
  expect(controller.canUndo, isTrue);
  await store.outbox(); // settle queued snapshot writes before the race
  return (controller: controller, api: api, store: store, haptics: haptics);
}

Future<void> _replaceQueue(ReviewController controller, _Api api) async {
  api.queueOffline = false;
  await controller.selectDeck(2);
  await controller.store.outbox();
  expect(controller.state.current?.id, 201);
  expect(controller.state.index, 0);
}

Future<void> _switchOwner(
  ReviewController controller,
  _Api api,
  _Store store,
) async {
  api.queueOffline = false;
  await api.signIn(email: _ownerBEmail, password: 'invented-password');
  await _until(
    () => store.isActiveOwner(api.currentUser!.id) && !controller.state.loading,
  );
  await _replaceQueue(controller, api);
  await store.saveCatchUpState(
    const CatchUpLocalState(
      mode: CatchUpMode.active,
      dayKey: _day,
      completedToday: 11,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final switchOwner in [false, true]) {
    test(
      'Undo after removal leaves replacement ${switchOwner ? 'owner' : 'deck'} intact',
      () async {
        final (:controller, :api, :store, :haptics) = await _session();
        final ownerA = store.activeOwnerScope!;
        final gate = _Gate();
        addTearDown(gate.open);
        store.afterRemove = gate;
        final undoing = controller.undo();
        await gate.entered.future;
        expect(
          (await store.outbox(ownerScope: ownerA)).map((e) => e['card_id']),
          [101],
        );
        if (switchOwner) {
          await _switchOwner(controller, api, store);
        } else {
          await _replaceQueue(controller, api);
        }
        final replacement = controller.state;
        final local = await store.loadCatchUpState();
        final snapshots = store.snapshots;
        final attempts = api.attempts.length;
        gate.open();
        await undoing;
        await store.outbox();
        expect(controller.state, same(replacement));
        expect(await store.loadCatchUpState(), local);
        expect(store.snapshots, snapshots);
        expect(haptics, isEmpty);
        expect(controller.canUndo, isFalse);
        expect(controller.undoInFlight, isFalse);
        expect(controller.flagNotice, isNull);
        expect(api.attempts.length, attempts);
        expect(api.remoteUndos, 0);
        expect(
          (await store.outbox(ownerScope: ownerA)).map((e) => e['card_id']),
          [101],
        );
      },
    );
  }

  for (final pauseAtRead in [true, false]) {
    test(
      'owner switch during catch-up ${pauseAtRead ? 'read' : 'save'} cannot restore B progress',
      () async {
        final (:controller, :api, :store, :haptics) = await _session();
        final ownerA = store.activeOwnerScope!;
        final gate = _Gate();
        addTearDown(gate.open);
        if (pauseAtRead) {
          store.beforeCatchUpRead = gate;
        } else {
          store.beforeCatchUpSave = gate;
        }
        final undoing = controller.undo();
        await gate.entered.future;
        await _switchOwner(controller, api, store);
        final replacement = controller.state;
        final local = await store.loadCatchUpState();
        final snapshots = store.snapshots;
        gate.open();
        await undoing;
        await store.outbox();
        expect(await store.loadCatchUpState(), local);
        expect(controller.state, same(replacement));
        expect(store.snapshots, snapshots);
        expect(haptics, isEmpty);
        expect(controller.canUndo, isFalse);
        expect(controller.flagNotice, isNull);
        expect(api.remoteUndos, 0);
        expect(
          (await store.outbox(ownerScope: ownerA)).map((e) => e['card_id']),
          [101],
        );
      },
    );
  }

  test(
    'owner switch before removal pins Undo to A even with a matching B event id',
    () async {
      final (:controller, :api, :store, :haptics) = await _session();
      final ownerA = store.activeOwnerScope!;
      final original = (await store.outbox(ownerScope: ownerA)).last;
      final gate = _Gate();
      addTearDown(gate.open);
      store.beforeRemove = gate;
      final undoing = controller.undo();
      await gate.entered.future;
      await _switchOwner(controller, api, store);
      await store.enqueueReview({
        'client_id': original['client_id'],
        'card_id': 201,
      });
      final bOutbox = await store.outbox();
      final replacement = controller.state;
      final local = await store.loadCatchUpState();
      gate.open();
      await undoing;
      expect(await store.outbox(), bOutbox);
      expect(
        (await store.outbox(ownerScope: ownerA)).map((e) => e['card_id']),
        [101],
      );
      expect(await store.loadCatchUpState(), local);
      expect(controller.state, same(replacement));
      expect(controller.flagNotice, isNull);
      expect(haptics, isEmpty);
      expect(api.remoteUndos, 0);
    },
  );

  test('stale refusal cannot show a synced-Undo notice in B', () async {
    final (:controller, :api, :store, :haptics) = await _session();
    final ownerA = store.activeOwnerScope!;
    final eventId =
        (await store.outbox(ownerScope: ownerA)).last['client_id'] as Object;
    await store.markReviewAttempted(eventId, ownerScope: ownerA);
    final gate = _Gate();
    addTearDown(gate.open);
    store.beforeRemove = gate;
    final undoing = controller.undo();
    await gate.entered.future;
    await _switchOwner(controller, api, store);
    final original = await store.outbox(ownerScope: ownerA);
    final replacement = controller.state;
    gate.open();
    await undoing;
    expect(controller.flagNotice, isNull);
    expect(controller.state, same(replacement));
    expect(await store.outbox(ownerScope: ownerA), original);
    expect(await store.outbox(), isEmpty);
    expect(haptics, isEmpty);
    expect(api.remoteUndos, 0);
  });

  test('sign-out after removal remains signed out when Undo settles', () async {
    final (:controller, :api, :store, :haptics) = await _session();
    final ownerA = store.activeOwnerScope!;
    final gate = _Gate();
    addTearDown(gate.open);
    store.afterRemove = gate;
    final undoing = controller.undo();
    await gate.entered.future;
    await api.signOut();
    await _until(
      () => store.activeOwnerScope == null && controller.state.queue.isEmpty,
    );
    final signedOut = controller.state;
    final snapshots = store.snapshots;
    gate.open();
    await undoing;
    expect(controller.state, same(signedOut));
    expect(controller.state.queue, isEmpty);
    expect(controller.canUndo, isFalse);
    expect(controller.undoInFlight, isFalse);
    expect(controller.flagNotice, isNull);
    expect(store.snapshots, snapshots);
    expect(haptics, isEmpty);
    expect(api.remoteUndos, 0);
    expect((await store.outbox(ownerScope: ownerA)).map((e) => e['card_id']), [
      101,
    ]);
  });

  test(
    'current-session Undo still restores the exact local review and catch-up slot once',
    () async {
      final (:controller, :api, :store, :haptics) = await _session();
      final rated = controller.state;
      await controller.undo();
      expect(controller.state.current?.id, 102);
      expect(controller.state.index, 1);
      expect(controller.state.reviewedThisSession, 1);
      expect(controller.state.globalDueCount, rated.globalDueCount! + 1);
      expect(controller.state.catchUp.completedToday, 5);
      expect((await store.loadCatchUpState()).completedToday, 5);
      expect(controller.state.pendingSync, 1);
      expect((await store.outbox()).single['card_id'], 101);
      expect(haptics, ['undo']);
      expect(api.remoteUndos, 0);
      expect(controller.canUndo, isFalse);
      await controller.undo();
      expect(haptics, ['undo']);
    },
  );
}

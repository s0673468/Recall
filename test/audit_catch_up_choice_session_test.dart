import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

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
  _Gate? readGate;
  _Gate? writeGate;

  @override
  Future<CatchUpLocalState> loadCatchUpState() async {
    final gate = readGate;
    readGate = null;
    final result = await super.loadCatchUpState();
    if (gate != null) await gate.hold();
    return result;
  }

  @override
  Future<void> saveCatchUpState(
    CatchUpLocalState state, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    final gate = writeGate;
    writeGate = null;
    if (gate != null) await gate.hold();
    return super.saveCatchUpState(
      state,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
  }
}

User _user(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-10-17T00:00:00Z',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 17, 12);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ReviewController, FakeRecallApi, _Store)> session() async {
    final api = FakeRecallApi(
      [
        for (var id = 1; id <= 90; id++)
          testCard(
            id: id,
            state: 2,
            stability: 5,
            difficulty: 5,
            reps: 2,
            due: now.subtract(const Duration(days: 1)),
            lastReview: now.subtract(const Duration(days: 5)),
          ),
        testCard(id: 100, deckId: 2),
      ],
      decks: const [
        DeckRow(deckId: 1, name: 'Synthetic backlog'),
        DeckRow(deckId: 2, name: 'Synthetic small deck'),
      ],
    )..user = _user('synthetic-choice-owner-a');
    final store = _Store();
    await store.activateOwner(api.currentUser!.id);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.catchUp.shouldOffer, isTrue);
    return (controller, api, store);
  }

  for (final holdWrite in [false, true]) {
    for (final switchOwner in [false, true]) {
      test('catch-up choice waiting on ${holdWrite ? 'write' : 'read'} '
          'expires after ${switchOwner ? 'owner' : 'deck'} switch', () async {
        final (controller, api, store) = await session();
        final originalOwner = store.activeOwnerScope;
        final originalLocal = await store.loadCatchUpState();
        final gate = _Gate();
        addTearDown(gate.open);
        if (holdWrite) {
          store.writeGate = gate;
        } else {
          store.readGate = gate;
        }
        final choice = controller.startCatchUp();
        await gate.entered.future;

        if (switchOwner) {
          api.user = _user('synthetic-choice-owner-b');
          await store.activateOwner(api.currentUser!.id);
          await controller.load();
        } else {
          await controller.selectDeck(2);
        }
        final currentQueue = controller.state.queue;
        final currentView = controller.state.catchUp;
        final currentLocal = await store.loadCatchUpState();
        gate.open();
        await choice;

        expect(await store.loadCatchUpState(), currentLocal);
        expect(
          await store.loadCatchUpStateForOwner(originalOwner),
          switchOwner ? originalLocal : currentLocal,
        );
        expect(controller.state.queue, same(currentQueue));
        expect(controller.state.catchUp, same(currentView));
      });
    }
  }
}

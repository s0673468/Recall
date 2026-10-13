import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_acceptance_fixture.dart';

final _now = DateTime(2026, 10, 13, 12);
const _waitLimit = Duration(seconds: 5);

enum _CommitStage { outbox, catchUp }

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

// Only the platform acknowledgement is delayed. The production store still
// owns the writer lock and SharedPreferences still updates its cache first.
class _NativePrefs extends InMemorySharedPreferencesStore {
  _NativePrefs() : super.empty();

  _Gate? outboxWrite;
  _Gate? catchUpWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _Gate? gate;
    if (key.contains('recall_outbox_v1')) {
      gate = outboxWrite;
      outboxWrite = null;
    } else if (key.contains(LocalReviewStore.catchUpKey)) {
      gate = catchUpWrite;
      catchUpWrite = null;
    }
    if (gate != null) await gate.hold();
    return super.setValue(valueType, key, value);
  }
}

class _Api extends SanitizedRecallApi {
  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [
            for (var id = 501; id <= 583; id++)
              ReviewCard(
                id: id,
                guid: 'invented-undo-ack-$id',
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
              ),
          ],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.offline,
      );

  final attempts = <int>[];

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    attempts.add((entry['card_id'] as num).toInt());
    throw StateError('invented offline transport');
  }
}

Future<T> _bounded<T>(Future<T> future) => future.timeout(_waitLimit);

Future<void> _race(_CommitStage stage) async {
  final previousPlatform = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _NativePrefs();
  SharedPreferencesStorePlatform.instance = native;
  final api = _Api();
  final store = LocalReviewStore();
  final gate = _Gate();
  final work = <Future<void>>[];
  ReviewController? disposable;
  Future<void> track(Future<void> future) {
    work.add(future);
    return future;
  }

  addTearDown(() async {
    gate.open();
    disposable?.dispose();
    try {
      await _bounded(
        Future.wait([
          for (final future in work) future.catchError((Object _) {}),
        ]),
      );
      await _bounded(store.outbox());
      await _bounded(store.flagOutbox());
    } finally {
      api.disposeFixture();
      SharedPreferencesStorePlatform.instance = previousPlatform;
      SharedPreferences.resetStatic();
    }
  });

  // Existing invented owner only: no auth event can launch an extra load.
  await _bounded(store.activateOwner(api.currentUser!.id));
  await _bounded(
    store.saveSnapshot(
      decks: api.dataset.decks,
      queue: api.dataset.cards,
      deckId: 1,
      globalDueCount: api.dataset.cards.length,
      globalDueUpdatedAt: _now,
    ),
  );
  await _bounded(
    store.saveCatchUpState(
      const CatchUpLocalState(
        mode: CatchUpMode.active,
        dayKey: '2026-10-13',
      ),
    ),
  );
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
    clock: () => _now,
  );
  disposable = controller;
  await _bounded(track(controller.load(deckId: 1)));
  expect(controller.state.offline, isTrue);
  expect(controller.state.catchUp.isActive, isTrue);
  final cardA = controller.state.current!.id;
  controller.flip();
  await _bounded(track(controller.rate(Rating.good)));
  final first = (await _bounded(store.outbox())).single;
  final clientA = first['client_id'];
  expect(first['card_id'], cardA);
  expect(first['delivery_attempted'], isFalse);
  expect(controller.canUndo, isTrue);

  final cardB = controller.state.current!.id;
  expect(cardB, isNot(cardA));
  controller.flip();
  if (stage == _CommitStage.outbox) {
    native.outboxWrite = gate;
  } else {
    native.catchUpWrite = gate;
  }
  final rating = track(controller.rate(Rating.good));
  await _bounded(gate.entered.future);
  final pendingPresentation = controller.state;
  final prefs = await _bounded(SharedPreferences.getInstance());
  final outboxKey = prefs.getKeys().singleWhere(
    (key) => key.contains('recall_outbox_v1'),
  );
  final cached = [
    for (final entry in jsonDecode(prefs.getString(outboxKey)!) as List)
      Map<String, dynamic>.from(entry as Map),
  ];
  final clientB = cached.singleWhere((entry) => entry['card_id'] == cardB)[
      'client_id'];
  expect(clientB, isNot(clientA));
  expect(controller.rateInFlight, isTrue);
  expect(pendingPresentation.current?.id, cardB);
  expect(pendingPresentation.showBack, isTrue);
  expect(pendingPresentation.reviewedThisSession, 1);

  // Main may already hold Undo B here; the blocked source still holds Undo A.
  // Both must reject Undo until the rating's whole local commit has settled.
  final availableDuringCommit = controller.canUndo;
  final prematureUndo = track(controller.undo());
  expect(availableDuringCommit, isFalse);
  expect(controller.undoInFlight, isFalse);
  expect(identical(controller.state, pendingPresentation), isTrue);
  await _bounded(prematureUndo);
  gate.open();
  await _bounded(Future.wait([rating, prematureUndo]));

  final committed = await _bounded(store.outbox());
  expect(committed, hasLength(2));
  expect(committed.map((entry) => entry['card_id']), [cardA, cardB]);
  expect(committed.map((entry) => entry['client_id']), [clientA, clientB]);
  expect(committed.every((entry) => entry['delivery_attempted'] == false), isTrue);
  expect(controller.state.current!.id, isNot(anyOf(cardA, cardB)));
  expect(controller.state.showBack, isFalse);
  expect(controller.state.reviewedThisSession, 2);
  expect(controller.state.catchUp.completedToday, 2);
  expect(controller.state.catchUp.dueCount, api.dataset.cards.length - 2);
  expect(
    controller.state.queue
        .skip(controller.state.index)
        .map((card) => card.id),
    isNot(anyElement(anyOf(cardA, cardB))),
  );
  // A second rating press cannot commit either consumed card again.
  await _bounded(controller.rate(Rating.good));
  expect(
    (await _bounded(store.outbox())).map((entry) => entry['client_id']),
    [clientA, clientB],
  );
  expect(api.attempts, isEmpty);
  expect(controller.canUndo, isTrue);

  // The interlock expires with B's commit. Its new, unsent Undo slot still
  // restores B while preserving A's original durable review.
  await _bounded(track(controller.undo()));
  final afterUndo = await _bounded(store.outbox());
  expect(afterUndo, hasLength(1));
  expect(afterUndo.single['card_id'], cardA);
  expect(afterUndo.single['client_id'], clientA);
  expect(controller.state.current?.id, cardB);
  expect(controller.state.showBack, isFalse);
  expect(controller.state.reviewedThisSession, 1);
  expect(controller.state.catchUp.completedToday, 1);
  expect(controller.state.catchUp.dueCount, api.dataset.cards.length - 1);
  expect(controller.rateInFlight, isFalse);
  expect(controller.undoInFlight, isFalse);
}

void main() {
  test(
    'Undo stays unavailable while the next rating awaits its native outbox acknowledgement',
    () => _race(_CommitStage.outbox),
  );
  test(
    'Undo stays unavailable while the next rating awaits its native catch-up acknowledgement',
    () => _race(_CommitStage.catchUp),
  );
}

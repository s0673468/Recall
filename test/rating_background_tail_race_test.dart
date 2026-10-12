import 'dart:async';

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
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_acceptance_fixture.dart';

final _now = DateTime.utc(2026, 10, 12, 12);

List<ReviewCard> _inventedCards() => [
  for (var id = 101; id <= 183; id++)
    ReviewCard(
      id: id,
      guid: 'invented-native-ack-$id',
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
      tags: id == 101 ? 'node::invented-native-ack-concept' : null,
    ),
];

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

class _NativePrefs extends InMemorySharedPreferencesStore {
  _NativePrefs() : super.empty();
  _Gate? reviewWrite;
  _Gate? remediationWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _Gate? gate;
    if (key.contains('recall_outbox_v1')) {
      gate = reviewWrite;
      reviewWrite = null;
    } else if (key.contains(LocalReviewStore.remediationKey)) {
      gate = remediationWrite;
      remediationWrite = null;
    }
    if (gate != null) await gate.hold();
    return super.setValue(valueType, key, value);
  }
}

class _Api extends SanitizedRecallApi {
  _Api({required this.hideUpcoming})
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: _inventedCards(),
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  final bool hideUpcoming;
  final queueRead = _Gate();
  bool firstQueue = true;

  @override
  Future<Set<int>> fetchHiddenCardIds() async => hideUpcoming ? {102} : {};

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    if (firstQueue) {
      firstQueue = false;
      await queueRead.hold();
    }
    return [
      for (final card in dataset.cards)
        if (!excludeCardIds.contains(card.id) &&
            (hideUpcoming || card.id != 183))
          card,
    ];
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async =>
      throw StateError('invented offline transport');
}

Future<void> _turns([int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final hideUpcoming in [true, false]) {
    test(
      hideUpcoming
          ? 'native-ack overlap advances durable rating after upcoming hide'
          : 'native-ack overlap preserves refreshed catch-up source',
      () async {
        final previousPlatform = SharedPreferencesStorePlatform.instance;
        SharedPreferences.resetStatic();
        final native = _NativePrefs();
        SharedPreferencesStorePlatform.instance = native;
        final api = _Api(hideUpcoming: hideUpcoming);
        final store = LocalReviewStore(); // No store subclass or method delays.
        final reviewAck = _Gate();
        final remediationAck = _Gate();
        ReviewController? disposable;
        addTearDown(() {
          reviewAck.open();
          remediationAck.open();
          api.queueRead.open();
          disposable?.dispose();
          api.disposeFixture();
          SharedPreferencesStorePlatform.instance = previousPlatform;
          SharedPreferences.resetStatic();
        });
        await api.signIn(
          email: 'invented-native-ack@example.invalid',
          password: 'invented-password',
        );
        await store.activateOwner(api.currentUser!.id);
        await store.saveSnapshot(
          decks: api.dataset.decks,
          queue: api.dataset.cards,
        );
        await store.saveCatchUpState(
          const CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: '2026-10-12',
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
        var loadFinished = false;
        final load = controller.load().then((_) {
          loadFinished = true;
        });
        await api.queueRead.entered.future;
        await _turns();
        expect(await store.hiddenCardIds(), hideUpcoming ? {102} : isEmpty);
        expect(controller.state.current?.id, 101);
        controller.flip();
        native.reviewWrite = reviewAck;
        native.remediationWrite = remediationAck;
        final rating = controller.rate(Rating.again);
        await reviewAck.entered.future;
        // Let the load's outbox read queue before the remediation write.
        api.queueRead.open();
        await _turns();
        reviewAck.open();
        await remediationAck.entered.future;
        await _turns();
        // On the blocked head the unlocked catch-up read lets load finish here;
        // the serialization split may instead hold it until the native ack.
        // Both orders must settle to the same safe durable-rating outcome.
        expect(controller.state.current?.id, 101);
        expect(controller.rateInFlight, isTrue);
        remediationAck.open();
        await Future.wait([rating, load]);
        expect(loadFinished, isTrue);
        expect(controller.state.current?.id, hideUpcoming ? 103 : 102);
        expect(controller.state.showBack, isFalse);
        expect(controller.state.reviewedThisSession, 1);
        expect(controller.rateInFlight, isFalse);
        final committed = (await store.outbox()).single;
        expect(committed['card_id'], 101);
        final clientId = committed['client_id'];
        // A repeated press on the new unrevealed card cannot duplicate A.
        await controller.rate(Rating.again);
        expect((await store.outbox()).single['client_id'], clientId);
        await controller.showAll();
        expect(
          controller.state.queue.map((card) => card.id),
          isNot(contains(101)),
        );
        expect(
          controller.state.queue.map((card) => card.id),
          isNot(contains(hideUpcoming ? 102 : 183)),
        );
      },
    );
  }
}

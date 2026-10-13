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

final _now = DateTime.utc(2026, 10, 13, 12);
const _ratedCardId = 301;
const _lastCardId = 325;
const _remainingDueCount = _lastCardId - _ratedCardId;
const _awaitLimit = Duration(seconds: 5);

List<ReviewCard> _inventedCards() => [
  for (var id = _ratedCardId; id <= _lastCardId; id++)
    ReviewCard(
      id: id,
      guid: 'invented-refresh-progress-$id',
      deckId: 1,
      front: 'Invented backlog front $id',
      back: 'Invented backlog back $id',
      hasLatex: false,
      stability: 4,
      difficulty: 5,
      due: _now.subtract(const Duration(days: 1)),
      state: 2,
      reps: 3,
      lapses: 0,
      lastReview: _now.subtract(const Duration(days: 5)),
      cloudSeen: true,
      tags: id == _ratedCardId
          ? 'node::invented-refresh-progress-concept'
          : null,
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

/// Delay only native persistence acknowledgements. The production store's
/// locking and SharedPreferences' earlier memory-cache update remain intact.
class _NativePrefs extends InMemorySharedPreferencesStore {
  _NativePrefs() : super.empty();

  _Gate? reviewWrite;
  _Gate? remediationWrite;
  _Gate? catchUpWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _Gate? gate;
    if (key.contains('recall_outbox_v1')) {
      gate = reviewWrite;
      reviewWrite = null;
    } else if (key.contains(LocalReviewStore.remediationKey)) {
      gate = remediationWrite;
      remediationWrite = null;
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
          cards: _inventedCards(),
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  final queueRead = _Gate();
  final queueReturned = Completer<void>();
  List<int> returnedCardIds = const [];
  bool firstQueue = true;

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    final gated = firstQueue;
    firstQueue = false;
    if (gated) await queueRead.hold();
    final cards = await super.fetchQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      newLimit: newLimit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
    if (gated) {
      returnedCardIds = [for (final card in cards) card.id];
      queueReturned.complete();
    }
    return cards;
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async =>
      throw StateError('invented offline transport');
}

Future<T> _bounded<T>(Future<T> future) => future.timeout(_awaitLimit);

/// Let ready load continuations reach the production store lock. A native
/// acknowledgement gate still controls when those operations can finish.
Future<void> _settleTurns() async {
  for (var i = 0; i < 2; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final refreshBeforeProgress in [true, false]) {
    test(
      refreshBeforeProgress
          ? 'refresh queued behind native rating ack preserves expanded catch-up progress'
          : 'refresh completing during native progress ack preserves expanded catch-up progress',
      () async {
        final previousPlatform = SharedPreferencesStorePlatform.instance;
        SharedPreferences.resetStatic();
        final native = _NativePrefs();
        SharedPreferencesStorePlatform.instance = native;
        final api = _Api();
        final store = LocalReviewStore();
        final reviewAck = _Gate();
        final remediationAck = _Gate();
        final progressAck = _Gate();
        final operations = <Future<void>>[];
        ReviewController? disposable;
        addTearDown(() async {
          for (final gate in [
            api.queueRead,
            reviewAck,
            remediationAck,
            progressAck,
          ]) {
            gate.open();
          }
          try {
            await _bounded(Future.wait(operations));
          } catch (_) {
            // A failed assertion must still release every fixture gate.
          }
          disposable?.dispose();
          await _settleTurns();
          api.disposeFixture();
          SharedPreferencesStorePlatform.instance = previousPlatform;
          SharedPreferences.resetStatic();
        });
        await _bounded(
          api.signIn(
            email: 'invented-refresh-progress@example.invalid',
            password: 'invented-password',
          ),
        );
        await _bounded(store.activateOwner(api.currentUser!.id));
        // The cache knows only A. The background fetch returns A plus 24
        // additional due cards, including cards beyond today's daily cap.
        await _bounded(
          store.saveSnapshot(
            decks: api.dataset.decks,
            queue: [api.dataset.cards.first],
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
        final load = controller.load();
        operations.add(load);
        await _bounded(api.queueRead.entered.future);
        expect(controller.state.current?.id, _ratedCardId);
        expect(controller.state.catchUp.mode, CatchUpMode.active);
        expect(controller.state.catchUp.dueCount, 1);
        expect(controller.state.catchUp.completedToday, 0);
        controller.flip();
        native.reviewWrite = reviewAck;
        native.remediationWrite = remediationAck;
        native.catchUpWrite = progressAck;
        final rating = controller.rate(Rating.again);
        operations.add(rating);
        await _bounded(reviewAck.entered.future);

        if (refreshBeforeProgress) {
          // Load's fresh outbox read queues behind A's pending native write.
          // Its source therefore already excludes A when progress catches up.
          api.queueRead.open();
          await _bounded(api.queueReturned.future);
          await _settleTurns();
        }
        expect(controller.state.current?.id, _ratedCardId);
        expect(controller.state.showBack, isTrue);
        expect(controller.rateInFlight, isTrue);
        reviewAck.open();
        await _bounded(remediationAck.entered.future);
        remediationAck.open();
        await _bounded(progressAck.entered.future);

        if (!refreshBeforeProgress) {
          // The fresh read arrives while native progress is unacknowledged.
          // This is still the same background load, not a later new session.
          api.queueRead.open();
          await _bounded(api.queueReturned.future);
          await _settleTurns();
        }
        expect(
          api.returnedCardIds,
          orderedEquals([
            for (var id = _ratedCardId; id <= _lastCardId; id++) id,
          ]),
          reason: 'The fresh server source contains A and the added backlog',
        );
        expect(controller.rateInFlight, isTrue);
        // Refresh may publish before or after this acknowledgement. Either
        // order must produce the same durable progress and remaining source.
        progressAck.open();
        await _bounded(Future.wait([rating, load]));

        expect(controller.rateInFlight, isFalse);
        expect(controller.state.reviewedThisSession, 1);
        expect(controller.state.showBack, isFalse);
        expect(
          controller.state.catchUp.mode,
          CatchUpMode.active,
          reason: 'One cached card was not the whole refreshed backlog',
        );
        expect(
          controller.state.catchUp.dueCount,
          _remainingDueCount,
          reason: 'A was already filtered by its outbox; do not subtract twice',
        );
        expect(controller.state.catchUp.completedToday, 1);
        expect(
          await _bounded(store.loadCatchUpState()),
          const CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: '2026-10-13',
            completedToday: 1,
          ),
        );
        final committed = await _bounded(store.outbox());
        expect(committed, hasLength(1));
        expect(committed.single['card_id'], _ratedCardId);

        // The fresh source survives behind the active plan's daily slice.
        // This also proves A cannot reappear when the learner shows all cards.
        await _bounded(controller.showAll());
        expect(
          controller.state.queue.map((card) => card.id),
          orderedEquals([
            for (var id = _ratedCardId + 1; id <= _lastCardId; id++) id,
          ]),
        );
        expect(
          controller.state.catchUp.dueCount,
          controller.state.queue
              .where(
                (card) =>
                    !card.isNew && card.due != null && !card.due!.isAfter(_now),
              )
              .length,
        );
        expect(controller.state.catchUp.completedToday, 1);
        expect(controller.state.reviewedThisSession, 1);
      },
    );
  }
}

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

// Local calendar times keep the midnight boundary independent of the host's
// timezone. The cards, account and transport are all invented fixture data.
final _beforeMidnight = DateTime(2026, 10, 13, 23, 59);
final _afterMidnight = DateTime(2026, 10, 14, 0, 1);
const _waitLimit = Duration(seconds: 5);

class _SharedPreferencesStub extends InMemorySharedPreferencesStore {
  _SharedPreferencesStub() : super.empty();
}

class _Api extends SanitizedRecallApi {
  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _beforeMidnight,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [
            for (var id = 101; id <= 183; id++)
              ReviewCard(
                id: id,
                guid: 'invented-midnight-progress-$id',
                deckId: 1,
                front: 'Invented front $id',
                back: 'Invented back $id',
                hasLatex: false,
                stability: 4,
                difficulty: 5,
                due: _beforeMidnight.subtract(const Duration(days: 1)),
                state: 2,
                reps: 3,
                lapses: 0,
                lastReview: _beforeMidnight.subtract(const Duration(days: 5)),
                cloudSeen: true,
              ),
          ],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  final attemptedCardIds = <int>[];

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    attemptedCardIds.add((entry['card_id'] as num).toInt());
    throw StateError('invented failed review delivery');
  }
}

void main() {
  test(
    'active catch-up rating across midnight resets today and preserves both reviews',
    () async {
      final previousPlatform = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _SharedPreferencesStub();
      final api = _Api();
      final store = LocalReviewStore();
      var now = _beforeMidnight;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        haptics: const ReviewHaptics(),
        clock: () => now,
      );
      final work = <Future<void>>[];
      Future<void> finish(Future<void> future) {
        work.add(future);
        return future.timeout(_waitLimit);
      }

      addTearDown(() async {
        controller.dispose();
        try {
          await Future.wait([
            for (final future in work) future.catchError((Object _) {}),
          ]).timeout(_waitLimit);
          await controller.syncPending().timeout(_waitLimit);
          // Drain the detached initial snapshot before resetting global prefs.
          await store.outbox().timeout(_waitLimit);
        } finally {
          api.disposeFixture();
          SharedPreferencesStorePlatform.instance = previousPlatform;
          SharedPreferences.resetStatic();
        }
      });

      // The fake API already owns an invented user. Activate it directly so
      // no auth event starts another load during this single study session.
      await store.activateOwner(api.currentUser!.id).timeout(_waitLimit);
      await store
          .saveCatchUpState(
            const CatchUpLocalState(
              mode: CatchUpMode.active,
              dayKey: '2026-10-13',
              completedToday: 7,
            ),
          )
          .timeout(_waitLimit);
      await finish(controller.load(deckId: 1));
      expect(controller.state.current, isNotNull);
      final firstCardId = controller.state.current!.id;
      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.catchUp.completedToday, 7);
      expect(controller.state.catchUp.dueCount, 83);

      controller.flip();
      await finish(controller.rate(Rating.good));
      expect(
        await store.loadCatchUpState().timeout(_waitLimit),
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2026-10-13',
          completedToday: 8,
        ),
      );
      expect(controller.state.catchUp.completedToday, 8);
      expect(controller.state.catchUp.dueCount, 82);
      expect(controller.state.current, isNotNull);
      final secondCardId = controller.state.current!.id;
      expect(secondCardId, isNot(firstCardId));
      expect(controller.state.showBack, isFalse);

      // Continue on the next visible card without refreshing the queue. Its
      // UI still carries yesterday's eight completed cards when rating starts.
      now = _afterMidnight;
      controller.flip();
      await finish(controller.rate(Rating.good));
      await controller.syncPending().timeout(_waitLimit);
      expect(
        await store.loadCatchUpState().timeout(_waitLimit),
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2026-10-14',
          completedToday: 1,
        ),
      );
      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.catchUp.completedToday, 1);
      expect(controller.state.catchUp.remainingToday, 19);
      expect(controller.state.catchUp.dueCount, 81);
      expect(controller.state.current, isNotNull);
      expect(controller.state.current!.id, isNot(isIn([firstCardId, secondCardId])));
      expect(controller.state.showBack, isFalse);
      expect(controller.state.reviewedThisSession, 2);
      expect(controller.rateInFlight, isFalse);

      final pending = await store.outbox().timeout(_waitLimit);
      expect(pending, hasLength(2));
      expect(pending.map((entry) => entry['card_id']), [firstCardId, secondCardId]);
      final clientIds = pending
          .map((entry) => entry['client_id'] as String)
          .toSet();
      expect(clientIds, hasLength(2));
      expect(clientIds.every((id) => id.isNotEmpty), isTrue);
      expect(api.attemptedCardIds, isNotEmpty);
      expect(controller.state.pendingSync, 2);
    },
  );
}

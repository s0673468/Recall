import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/data/review_replay.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('review events identify the native iOS client', () {
    expect(
      recallDeviceLabel(isWeb: false, targetPlatform: TargetPlatform.iOS),
      'ios',
    );
  }, tags: const ['apple-mobile']);

  test('review events identify Android and web clients', () {
    expect(
      recallDeviceLabel(isWeb: false, targetPlatform: TargetPlatform.android),
      'android',
    );
    expect(
      recallDeviceLabel(isWeb: true, targetPlatform: TargetPlatform.android),
      'web',
    );
  });

  group('Multi-device sync', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    /// A card both devices already hold: reviewed three times, lapsed once.
    ReviewCard studied() => testCard(
      id: 5,
      state: 2,
      stability: 10,
      difficulty: 5,
      reps: 3,
      lapses: 1,
      due: DateTime.utc(2026, 6, 1),
      lastReview: DateTime.utc(2026, 5, 25),
      cloudSeen: true,
    );

    /// One device's queued review of that card. `reps`/`lapses` carry the
    /// absolute values computed off *this* device's snapshot — the numbers the
    /// unguarded replay used to write straight through.
    Map<String, dynamic> event({
      required String device,
      required DateTime at,
      required int rating,
      required int state,
      required bool lapsed,
      required double stability,
    }) => {
      'card_id': 5,
      'guid': 'g5',
      'stability': stability,
      'difficulty': 5.0,
      'due': at.add(const Duration(days: 10)).toIso8601String(),
      'state': state,
      'reps': 4,
      'lapses': lapsed ? 2 : 1,
      'last_review': at.toIso8601String(),
      'rating': rating,
      'device': device,
      'client_id': '$device-event-1',
      'lapsed': lapsed,
    };

    final morning = event(
      device: 'phone',
      at: DateTime.utc(2026, 6, 10, 9),
      rating: 3,
      state: 2,
      lapsed: false,
      stability: 20,
    );
    final evening = event(
      device: 'ipad',
      at: DateTime.utc(2026, 6, 10, 17),
      rating: 1,
      state: 3,
      lapsed: true,
      stability: 2,
    );

    /// Two devices, one server, flushing in the given order.
    Future<FakeServerCard> syncInOrder(List<Map<String, dynamic>> order) async {
      final server = FakeServer();
      final devices = {
        'phone': FakeRecallApi(
          [studied()],
          server: server,
          deviceLabel: 'phone',
        ),
        'ipad': FakeRecallApi([studied()], server: server, deviceLabel: 'ipad'),
      };
      for (final e in order) {
        await devices[e['device']]!.applyReview(e);
      }
      return server.cards[5]!;
    }

    test('two offline devices converge whichever order they sync', () async {
      final forward = await syncInOrder([morning, evening]);
      final reverse = await syncInOrder([evening, morning]);

      for (final card in [forward, reverse]) {
        // Both reviews really happened, so both are counted — accumulated from
        // server state rather than taken from either device's snapshot.
        expect(card.reps, 5);
        expect(card.lapses, 2);
        // The later review owns the schedule no matter when it arrives.
        expect(card.lastReview, DateTime.utc(2026, 6, 10, 17));
        expect(card.state, 3);
        expect(card.stability, 2);
      }
    });

    test('a late replay counts its rep without rewinding the card', () async {
      // Evening synced first; the morning review arrives afterwards. Its older
      // scheduling must not drag the card back to a due date already superseded.
      final api = FakeRecallApi([studied()]);
      await api.applyReview(evening);
      final scheduledDue = api.server.cards[5]!.due;

      await api.applyReview(morning);

      final card = api.server.cards[5]!;
      expect(card.due, scheduledDue);
      expect(card.stability, 2);
      expect(card.state, 3);
      expect(card.reps, 5); // still counted
    });

    test('reps and lapses never take a stale absolute snapshot', () async {
      // Both entries claim `reps: 4` off their own stale local card. Writing
      // either one through verbatim would lose the other device's review.
      final api = FakeRecallApi([studied()]);
      await api.applyReview(morning);
      expect(api.server.cards[5]!.reps, 4);
      expect(api.server.cards[5]!.lapses, 1);

      await api.applyReview(evening);
      expect(api.server.cards[5]!.reps, 5);
      expect(api.server.cards[5]!.lapses, 2);
    });

    test('a lost compare-and-swap re-merges instead of clobbering', () async {
      final api = FakeRecallApi([studied()]);
      // Another device commits between this replay's read and its write.
      var interposed = false;
      api.server.beforeCardUpdate = () async {
        if (interposed) return;
        interposed = true;
        api.server.cards[5]!
          ..reps += 1
          ..lastReview = DateTime.utc(2026, 6, 10, 12);
      };

      await api.applyReview(morning);

      expect(interposed, isTrue);
      // The interloper's rep survived and ours landed on top of it.
      expect(api.server.cards[5]!.reps, 5);
      // Its review was newer than ours, so it kept the schedule.
      expect(api.server.cards[5]!.lastReview, DateTime.utc(2026, 6, 10, 12));
    });

    test('a permanently contended card defers rather than corrupts', () async {
      final api = FakeRecallApi([studied()]);
      api.server.beforeCardUpdate = () async => api.server.cards[5]!.reps += 1;

      await expectLater(
        api.applyReview(morning),
        throwsA(isA<ReviewReplayConflict>()),
      );
      // Nothing logged: the review stays in the outbox for the next flush.
      expect(api.server.reviewLog, isEmpty);
    });

    test('a retry after a failed log insert does not double-count', () async {
      // applyReview merges the card first, then appends the log. A failure in
      // between leaves the outbox entry queued with no log row, so the next
      // flush's client_event_id probe finds nothing and retries the whole
      // apply. Since counters now accumulate from server state, repeating the
      // merge would inflate reps — the merge has to notice it already landed.
      final api = FakeRecallApi([studied()])..failLogInsert = true;

      await expectLater(api.applyReview(morning), throwsA(isA<StateError>()));
      expect(api.server.cards[5]!.reps, 4); // card merged
      expect(api.server.reviewLog, isEmpty); // log did not

      api.failLogInsert = false;
      await api.applyReview(morning); // the outbox retries it

      expect(api.server.cards[5]!.reps, 4); // not 5
      expect(api.server.cards[5]!.lapses, 1);
      expect(api.server.reviewLog, hasLength(1));
    });

    test('an exact timestamp tie leaves the first writer alone', () async {
      // Strict `isAfter` means equal timestamps do not win the schedule, so
      // two devices rating in the same instant resolve first-writer-wins
      // rather than thrashing on flush order.
      final api = FakeRecallApi([studied()]);
      final tie = {...evening, 'client_id': 'other-device', 'stability': 99.0};

      await api.applyReview(evening);
      await api.applyReview(tie);

      expect(api.server.cards[5]!.stability, 2); // first writer's scheduling
      // KNOWN RESIDUAL, pinned deliberately: the tie is indistinguishable from
      // our own partial apply, so the second review's rep is dropped — reps is
      // 4, not the 5 the "both reviews count" policy would give. Both events
      // are still logged, so the history is complete and the count is
      // recoverable. Fixing this needs true per-client_event_id idempotency
      // (a transactional RPC); see the README.
      expect(api.server.cards[5]!.reps, 4);
      expect(api.server.reviewLog, hasLength(2));
    });

    test('an unreadable last_review writes nothing at all', () async {
      // Failing closed on the whole row, not just the scheduling: a
      // counters-only patch would leave last_review untouched, so every retry
      // of this entry would add another phantom rep with no way to detect the
      // earlier merge.
      final server = CardSyncState.fromRow({
        'reps': 9,
        'lapses': 2,
        'last_review': 'not-a-timestamp',
      });

      expect(server.lastReviewUnreadable, isTrue);
      expect(mergeReviewIntoCard(server: server, entry: morning), isEmpty);
    });

    test('a never-reviewed card takes the incoming scheduling', () {
      // last_review IS NULL means nobody has reviewed it, so this review is
      // unambiguously the newest thing the row has ever seen.
      final server = CardSyncState.fromRow({
        'reps': 0,
        'lapses': 0,
        'last_review': null,
      });

      expect(server.lastReviewUnreadable, isFalse);
      final values = mergeReviewIntoCard(server: server, entry: morning);
      expect(values['due'], morning['due']);
      expect(values['reps'], 1);
    });

    test('a colliding client_event_id discards a genuine review', () async {
      // Why the durable id has to be unique: the server dedupes on it alone,
      // so two different reviews wearing the same id collapse into one.
      final api = FakeRecallApi([studied()]);
      final second = {...evening, 'client_id': morning['client_id']};

      await api.applyReview(morning);
      await api.applyReview(second);

      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[5]!.reps, 4); // the evening review vanished
    });

    test(
      'a restart with a rolled-back clock still delivers both reviews',
      () async {
        // The outbox survives a restart but the in-memory counters do not. If
        // the durable id were only clock+counter, a device whose clock rolled
        // back to the same instant would mint the same id twice and the server
        // would discard the second review as a replay.
        final at = DateTime.utc(2026, 7, 20, 12);
        final server = FakeServer();
        final store = LocalReviewStore();
        ReviewCard due(int id) => testCard(
          id: id,
          state: 2,
          stability: 10,
          difficulty: 5,
          reps: 3,
          due: DateTime.utc(2026, 7, 1),
          lastReview: DateTime.utc(2026, 6, 25),
        );

        Future<ReviewController> session(ReviewCard card) async {
          final api = FakeRecallApi([card], server: server)
            ..beforeApplyReview = () async => throw StateError('offline');
          final controller = ReviewController(
            api: api,
            engine: FsrsEngine(),
            store: store,
            clock: () => at,
          );
          await controller.load();
          controller.flip();
          await controller.rate(Rating.good);
          return controller;
        }

        final first = await session(due(1));
        first.dispose(); // app killed; sequence counters reset
        // A pending card is intentionally not served again after WP1. Use a
        // second real card to keep this ID-uniqueness fixture realizable.
        final second = await session(due(2));
        addTearDown(second.dispose);

        final queued = await store.outbox();
        expect(queued, hasLength(2));
        expect(queued[0]['client_id'], isNot(queued[1]['client_id']));

        // Back online: both must land as separate reviews.
        final api = FakeRecallApi([due(1), due(2)], server: server);
        final online = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => at,
        );
        addTearDown(online.dispose);
        await online.syncPending();

        expect(await store.outbox(), isEmpty);
        expect(server.reviewLog, hasLength(2));
        expect(server.cards[1]!.reps, 4);
        expect(server.cards[2]!.reps, 4);
      },
    );
  });
}

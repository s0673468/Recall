import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

const _outbox = 'flutter.recall_outbox_v1';
final _now = DateTime.utc(2026, 10, 23, 12);

// All storage and server state is invented and in memory. No HTTP is used.
class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.empty();

  bool? uncertainAppend;
  bool failReads = false;
  bool refuseAck = false;
  bool throwAfterAck = false;
  bool refuseAttempt = false;
  Map<String, dynamic>? attemptedAppend;

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) {
    if (failReads) throw StateError('synthetic read failure');
    return super.getAllWithParameters(parameters);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _outbox) {
      final rows = jsonDecode(value as String) as List;
      if (refuseAttempt &&
          rows.any((row) => (row as Map)['delivery_attempted'] == true)) {
        return false;
      }
      final commit = uncertainAppend;
      if (commit != null && rows.isNotEmpty) {
        uncertainAppend = null;
        attemptedAppend = Map<String, dynamic>.from(rows.last as Map);
        if (commit) await super.setValue(valueType, key, value);
        failReads = true;
        throw StateError('synthetic lost append reply');
      }
      if (rows.isEmpty) {
        if (refuseAck) return false;
        if (throwAfterAck) {
          await super.setValue(valueType, key, value);
          throw StateError('synthetic lost ACK reply');
        }
      }
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;

  setUp(() {
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    native = _Native();
    SharedPreferencesStorePlatform.instance = native;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    });
  });

  ReviewController controller(
    FakeRecallApi api,
    LocalReviewStore store, {
    DateTime Function()? clock,
  }) {
    final result = ReviewController(
      api: api,
      store: store,
      engine: FsrsEngine(),
      clock: clock ?? () => _now,
    );
    addTearDown(result.dispose);
    return result;
  }

  for (final committed in [false, true]) {
    for (final firstRating in [Rating.again, Rating.good]) {
      test('unconfirmed $firstRating keeps its immutable payload on retry '
          '(committed=$committed)', () async {
        final card = testCard(
          contentRevalidationPending: true,
          state: 2,
          reps: 3,
          stability: 4,
          difficulty: 5,
          due: _now.subtract(const Duration(days: 1)),
          lastReview: _now.subtract(const Duration(days: 5)),
          tags: 'node:synthetic-topic',
        );
        final api = FakeRecallApi([card, testCard(id: 2)]);
        final store = LocalReviewStore();
        var now = _now;
        final c = controller(api, store, clock: () => now);
        await c.load();
        await pumpEventQueue(); // Let the initial disposable snapshot land.
        api.beforeQueue = () async => throw const SocketException('synthetic');
        await c.refresh();
        expect(c.state.offline, isTrue);
        c.flip();
        native.uncertainAppend = committed;
        await expectLater(
          c.rate(firstRating),
          throwsA(isA<StudyActionUnconfirmedException>()),
        );
        final original = native.attemptedAppend!;
        expect(c.state.current?.id, 1);
        expect(c.state.reviewedThisSession, 0);

        native.failReads = false;
        // Retry after a clock change and a different button tap. A delivery
        // identity must continue to mean the same original review throughout.
        now = now.subtract(const Duration(hours: 2));
        await c.rate(firstRating == Rating.again ? Rating.good : Rating.again);
        expect((await store.outbox()).single, original);
        expect(c.state.lastReviewedAt, _now);
        expect(c.state.reviewedThisSession, 1);
        expect(c.state.current?.id, 2);
        final snapshot = await store.loadSnapshot();
        expect(
          snapshot!.queue.any((card) => card.id == 1),
          firstRating == Rating.again,
        );

        await c.syncPending();
        expect(api.server.reviewLog.single['rating'], original['rating']);
        expect(
          api.server.reviewLog.single['rating_at'],
          original['last_review'],
        );
        expect(api.server.cards[1]!.reps, 4);
        expect(await store.outbox(), isEmpty);

        // A later ordinary rating persists the source left by this recovery.
        // After delivery and an offline restart, a failed validation remains
        // available and a passed one does not return from stale scheduling.
        c.flip();
        await c.rate(Rating.good);
        await c.syncPending();
        SharedPreferences.resetStatic();
        final restarted = controller(api, LocalReviewStore());
        await restarted.initialize();
        expect(restarted.state.offline, isTrue);
        expect(
          restarted.state.queue.map((card) => card.id),
          firstRating == Rating.again ? [1] : isEmpty,
        );
      });
    }
  }

  for (final committed in [false, true]) {
    test('startup settles a failed local server-ACK write '
        '(committed=$committed) and can retry', () async {
      final card = testCard();
      final api = FakeRecallApi([card, testCard(id: 2)]);
      final store = LocalReviewStore();
      await store.enqueueReview({
        ...api.reviewEntry(
          card,
          FsrsEngine().review(card, Rating.good, now: _now),
        ),
        'client_id': 'synthetic-startup-ack',
      });
      native.refuseAck = !committed;
      native.throwAfterAck = committed;
      final c = controller(api, store);

      await expectLater(c.initialize(), completes);
      expect(c.state.loading, isFalse);
      expect(c.state.error, contains('pending study actions'));
      expect(c.state.offline, isFalse); // A local failure is not a radio loss.
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
      expect(await store.outbox(), hasLength(committed ? 0 : 1));

      native.refuseAck = false;
      native.throwAfterAck = false;
      // Reconstruct storage to exercise the durable retry after process death.
      SharedPreferences.resetStatic();
      final restartedStore = LocalReviewStore();
      final restarted = controller(api, restartedStore);
      await restarted.initialize();
      expect(restarted.state.loading, isFalse);
      expect(restarted.state.error, isNull);
      expect(restarted.state.pendingSync, 0);
      expect(await restartedStore.outbox(), isEmpty);
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
    });
  }

  test('reconnect can deliver an unconfirmed save before its retry', () async {
    final card = testCard();
    final api = FakeRecallApi([card, testCard(id: 2)]);
    final store = LocalReviewStore();
    var now = _now;
    final c = controller(api, store, clock: () => now);
    await c.load();
    await pumpEventQueue();
    native.uncertainAppend = true;
    c.flip();
    await expectLater(
      c.rate(Rating.good),
      throwsA(isA<StudyActionUnconfirmedException>()),
    );
    final original = native.attemptedAppend!;
    native.failReads = false;
    await c.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(api.server.reviewLog, hasLength(1));
    expect(c.state.current?.id, 1);

    now = now.add(const Duration(days: 1));
    await c.rate(Rating.again);
    await c.syncPending();
    expect(api.server.reviewLog, hasLength(1));
    expect(api.server.reviewLog.single['rating'], original['rating']);
    expect(api.server.cards[1]!.reps, 1);
    expect(c.state.lastReviewedAt, _now);
    expect(c.state.reviewedThisSession, 1);
    expect(c.state.current?.id, 2);
    expect(await store.outbox(), isEmpty);
  });

  test(
    'offline retry of a delivered uncertain save cannot reopen Undo',
    () async {
      final api = FakeRecallApi([testCard(), testCard(id: 2)]);
      final store = LocalReviewStore();
      final c = controller(api, store);
      await c.load();
      await pumpEventQueue();
      native.uncertainAppend = true;
      c.flip();
      await expectLater(
        c.rate(Rating.good),
        throwsA(isA<StudyActionUnconfirmedException>()),
      );
      native.failReads = false;
      await c.syncPending();
      expect(api.server.reviewLog, hasLength(1));
      expect(await store.outbox(), isEmpty);

      // The reply to the local save remains uncertain to the gesture even
      // though reconnect delivered it. Lose the connection again before retry.
      api.beforeQueue = () async => throw const SocketException('synthetic');
      await c.refresh();
      expect(c.state.offline, isTrue);
      expect(c.state.current?.id, 1);
      await c.rate(Rating.good);
      expect(c.state.current?.id, 2);
      expect(c.canUndo, isFalse);
      expect((await store.outbox()).single['delivery_attempted'], isTrue);
      await c.undo();
      expect(c.state.current?.id, 2);
      expect(c.state.reviewedThisSession, 1);
      await c.syncPending();
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
      expect(await store.outbox(), isEmpty);
    },
  );

  test(
    'startup retries a refused attempt marker without losing its review',
    () async {
      final card = testCard();
      final api = FakeRecallApi([card]);
      final store = LocalReviewStore();
      await store.enqueueReview({
        ...api.reviewEntry(
          card,
          FsrsEngine().review(card, Rating.good, now: _now),
        ),
        'client_id': 'synthetic-refused-attempt',
      });
      native.refuseAttempt = true;
      final c = controller(api, store);
      await c.initialize();
      // A refused marker is contained by the sender before transport, so queue
      // loading can proceed with that pending card excluded.
      expect(c.state.loading, isFalse);
      expect(c.state.pendingSync, 1);
      expect(c.state.queue, isEmpty);
      expect(api.server.reviewLog, isEmpty);
      expect((await store.outbox()).single['delivery_attempted'], isFalse);

      native.refuseAttempt = false;
      await c.refresh();
      expect(c.state.loading, isFalse);
      expect(c.state.error, isNull);
      expect(await store.outbox(), isEmpty);
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
    },
  );
}

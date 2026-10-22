import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

// Only synthetic scheduling state, an in-memory native backend and a fake
// server. No HTTP client, session tokens or external services are involved.
const _outboxKey = 'flutter.recall_outbox_v1';
final _serverNow = DateTime.utc(2026, 10, 22, 12);

Map<String, dynamic> _review(int id, DateTime at) => {
  'client_id': 'synthetic-resilience-$id',
  'card_id': id,
  'guid': 'g$id',
  'rating': 3,
  'last_review': at.toIso8601String(),
  'due': at.add(const Duration(days: 2)).toIso8601String(),
  'stability': 2.0,
  'difficulty': 5.0,
  'state': 2,
  'reps': 1,
  'lapses': 0,
  'lapsed': false,
  'device': 'android',
  'delivery_attempted': false,
};

class _Api extends FakeRecallApi {
  _Api(super.queue, {super.server});

  final attempts = <Map<String, dynamic>>[];
  Future<void> Function(Map<String, dynamic>)? beforeSend;
  Future<void> Function()? afterApply;

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    attempts.add(Map<String, dynamic>.from(entry));
    await beforeSend?.call(entry);
    final receipt = await super.applyReview(entry);
    await afterApply?.call();
    return receipt;
  }
}

/// Suspends one native write forever at a process-death boundary. A fresh
/// store drops all Dart caches and sees only the surviving native values.
class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.empty();

  bool? commitBeforeDeath;
  final died = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _outboxKey && commitBeforeDeath != null) {
      final commit = commitBeforeDeath!;
      commitBeforeDeath = null;
      if (commit) await super.setValue(valueType, key, value);
      died.complete();
      return Completer<bool>().future;
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

  LocalReviewStore restartStore() {
    SharedPreferences.resetStatic();
    return LocalReviewStore();
  }

  ReviewController controller(
    _Api api,
    LocalReviewStore store, {
    DateTime Function()? clock,
    Duration sendTimeout = const Duration(seconds: 5),
  }) {
    final result = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: clock ?? () => _serverNow,
      reviewSendTimeout: sendTimeout,
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'timeout after server apply survives restart without duplicate effects',
    () async {
      final api = _Api([testCard()]);
      final store = LocalReviewStore();
      final entry = _review(1, _serverNow);
      await store.enqueueReview(entry);
      final reply = Completer<void>();
      addTearDown(() => reply.complete());
      api.afterApply = () => reply.future;
      final first = controller(
        api,
        store,
        sendTimeout: const Duration(milliseconds: 50),
      );

      await first.syncPending().timeout(const Duration(seconds: 5));
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
      expect((await store.outbox()).single['client_id'], entry['client_id']);
      expect(first.state.pendingSync, 1);
      expect(first.state.offline, isTrue);

      final restartedStore = restartStore();
      final restartedApi = _Api([testCard()], server: api.server);
      final restarted = controller(restartedApi, restartedStore);
      await restarted.syncPending();

      expect(restartedApi.attempts.single['client_id'], entry['client_id']);
      expect(restartedApi.applied, isEmpty);
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
      expect(api.server.cards[1]!.due, DateTime.parse(entry['due'] as String));
      expect(await restartedStore.outbox(), isEmpty);
      expect(restarted.state.pendingSync, 0);
    },
  );

  for (final committed in [false, true]) {
    test(
      'kill at local outbox commit boundary: committed=$committed',
      () async {
        final api = _Api([testCard(), testCard(id: 2)]);
        final store = LocalReviewStore();
        final first = controller(api, store);
        await first.load();
        first.flip();
        native.commitBeforeDeath = committed;
        unawaited(first.rate(Rating.good));
        await native.died.future.timeout(const Duration(seconds: 5));

        // Advancing the card is gated by this same durable outbox write;
        // there is no separate local review write/enqueue gap to lose a rating.
        expect(first.state.current!.id, 1);
        expect(first.state.reviewedThisSession, 0);
        expect(api.attempts, isEmpty);

        final restartedStore = restartStore();
        final restartedApi = _Api(api.queue, server: api.server);
        restartedApi.beforeQueue = () async {
          throw const SocketException('synthetic');
        };
        restartedApi.beforeSend = (_) async {
          throw const SocketException('synthetic');
        };
        final restarted = controller(restartedApi, restartedStore);
        await restarted.load();
        expect(restarted.state.offline, isTrue);
        expect(restarted.state.current!.id, committed ? 2 : 1);
        expect(restarted.state.pendingSync, committed ? 1 : 0);

        if (!committed) {
          restarted.flip();
          await restarted.rate(Rating.good);
        }
        final durable = (await restartedStore.outbox()).single;
        restartedApi.beforeSend = null;
        await restarted.syncPending();
        expect(
          api.server.reviewLog.single['client_event_id'],
          durable['client_id'],
        );
        expect(api.server.cards[1]!.reps, 1);
        expect(await restartedStore.outbox(), isEmpty);
      },
    );
  }

  test(
    'partial batch drains only acknowledged entries and resumes after restart',
    () async {
      final api = _Api([for (var id = 1; id <= 5; id++) testCard(id: id)]);
      final store = LocalReviewStore();
      for (var id = 1; id <= 5; id++) {
        await store.enqueueReview(_review(id, _serverNow));
      }
      api.beforeSend = (entry) async {
        if (entry['card_id'] == 3) throw const SocketException('synthetic');
      };
      final first = controller(api, store);
      await first.syncPending();

      expect(api.server.reviewLog.map((e) => e['card_id']), [1, 2]);
      expect((await store.outbox()).map((e) => e['card_id']), [3, 4, 5]);
      expect(first.state.pendingSync, 3);
      final restartedStore = restartStore();
      final restartedApi = _Api(api.queue, server: api.server);
      await controller(restartedApi, restartedStore).syncPending();
      expect(restartedApi.attempts.map((e) => e['card_id']), [3, 4, 5]);
      expect(api.server.reviewLog.map((e) => e['card_id']), [1, 2, 3, 4, 5]);
      expect(api.server.cards.values.every((card) => card.reps == 1), isTrue);
      expect(await restartedStore.outbox(), isEmpty);
    },
  );

  for (final skew in [const Duration(days: -7), const Duration(days: 7)]) {
    test(
      'device clock skew $skew does not expire or re-identify pending reviews',
      () async {
        final card = testCard(
          state: 2,
          reps: 4,
          stability: 4,
          difficulty: 5,
          lastReview: _serverNow.subtract(const Duration(days: 1)),
          due: _serverNow,
        );
        final api = _Api([card]);
        final store = LocalReviewStore();
        var deviceNow = _serverNow.add(skew);
        final first = controller(api, store, clock: () => deviceNow);
        await first.load();
        api.beforeQueue = () async => throw const SocketException('synthetic');
        await first.refresh();
        expect(first.state.offline, isTrue);
        first.flip();
        // Also roll the clock back while the card is on screen.
        deviceNow = deviceNow.subtract(const Duration(minutes: 5));
        await first.rate(Rating.good);
        final durable = (await store.outbox()).single;
        expect(durable['last_review'], deviceNow.toIso8601String());
        expect(durable['elapsed_ms'], 0);

        final restartedStore = restartStore();
        final freshId = await restartedStore.newEventId();
        expect(freshId, isNot(durable['client_id']));
        final restartedApi = _Api([card], server: api.server);
        await controller(restartedApi, restartedStore).syncPending();
        expect(restartedApi.attempts.single['client_id'], durable['client_id']);
        expect(
          api.server.reviewLog.single['rating_at'],
          durable['last_review'],
        );
        expect(api.server.cards[1]!.reps, 5);
        // Keep the documented newest-review-wins policy under clock skew.
        expect(
          api.server.cards[1]!.lastReview,
          skew.isNegative ? card.lastReview : deviceNow,
        );
        expect(await restartedStore.outbox(), isEmpty);
      },
    );
  }

  test(
    'token expiry mid-sync stays retryable after session recovery',
    () async {
      final api = _Api([for (var id = 1; id <= 3; id++) testCard(id: id)])
        ..user = User(
          id: 'synthetic-resilience-owner',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '2026-10-01T00:00:00Z',
        );
      final store = LocalReviewStore();
      await store.activateOwner(api.currentUser!.id);
      for (var id = 1; id <= 3; id++) {
        await store.enqueueReview(_review(id, _serverNow));
      }
      var expired = true;
      api.beforeSend = (entry) async {
        if (entry['card_id'] == 2 && expired) {
          throw const PostgrestException(
            message: 'synthetic expired session',
            code: 'PGRST303',
          );
        }
      };
      final first = controller(api, store);
      await first.syncPending();
      final retained = await store.outbox();
      expect(retained.map((e) => e['card_id']), [2, 3]);
      expect(first.state.pendingSync, 2);
      expect(first.state.syncErrors, 0); // Auth failures must never be parked.

      expired = false; // Same owner's session recovered; no credential fixture.
      await first.syncPending();
      expect(api.attempts.map((e) => e['card_id']), [1, 2, 2, 3]);
      expect(api.server.reviewLog.map((e) => e['card_id']), [1, 2, 3]);
      expect(api.server.cards.values.every((card) => card.reps == 1), isTrue);
      expect(await store.outbox(), isEmpty);
      expect(first.state.pendingSync, 0);
      expect(first.state.syncErrors, 0);
    },
  );

  test(
    'a week offline retains and drains 3000 reviews across an interrupted sync',
    () async {
      const count = 3000;
      final entries = [
        for (var id = 1; id <= count; id++)
          _review(
            id,
            _serverNow.subtract(Duration(days: 7, seconds: count - id)),
          ),
      ];
      // Seed the durable state an offline app accumulated, avoiding thousands
      // of setup-only rewrites. All reads, marks, sends and drains are real.
      await native.setValue('String', _outboxKey, jsonEncode(entries));
      final api = _Api([for (var id = 1; id <= count; id++) testCard(id: id)]);
      final store = restartStore();
      api.beforeSend = (_) async => throw const SocketException('synthetic');
      final first = controller(api, store);
      await first.syncPending();
      expect(first.state.pendingSync, count);
      expect(
        await store.outbox(),
        entries
            .map(
              (e) => {...e, if (e['card_id'] == 1) 'delivery_attempted': true},
            )
            .toList(),
      );

      api.beforeSend = (entry) async {
        if (entry['card_id'] == 1201) throw const SocketException('synthetic');
      };
      await first.syncPending();
      expect(first.state.pendingSync, 1800);
      expect(api.server.reviewLog, hasLength(1200));
      final remaining = await store.outbox();
      expect(
        remaining.map((e) => e['client_id']),
        entries.skip(1200).map((e) => e['client_id']),
      );

      final restartedStore = restartStore();
      final restartedApi = _Api(api.queue, server: api.server);
      final restarted = controller(restartedApi, restartedStore);
      await restarted.syncPending();
      expect(restartedApi.attempts, hasLength(1800));
      expect(
        api.server.reviewLog.map((e) => e['client_event_id']),
        entries.map((e) => e['client_id']),
      );
      expect(api.server.cards.values.every((card) => card.reps == 1), isTrue);
      expect(await restartedStore.outbox(), isEmpty);
      expect(restarted.state.pendingSync, 0);
      expect(restarted.state.offline, isFalse);
    },
  );
}

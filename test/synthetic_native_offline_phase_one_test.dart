import 'dart:async';

// Parent destination: test/synthetic_native_offline_phase_one_test.dart.
// Generated rows and in-memory platform preferences; not native acceptance.
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';

import '../tool/fixtures/synthetic_native_offline_restart_main.dart';
import '../tool/fixtures/synthetic_recall_flow.dart';

Future<void> withGeneratedFlow(
  Future<void> Function(
    SyntheticNativeOfflineHttp transport,
    ReviewController controller,
    TimedLocalReviewStore store,
  )
  body,
) async {
  final transport = SyntheticNativeOfflineHttp(
    List.generate(20, (i) => syntheticCard(i + 1)),
    'invented-owner-hash',
  );
  final client = SupabaseClient(
    'https://recall-bench.invalid',
    'synthetic-public-key',
    httpClient: MockClient(transport.respond),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final api = SyntheticAuthRecallApi(client);
  final store = TimedLocalReviewStore();
  await store.activateOwner(api.currentUser!.id);
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
  );
  try {
    await body(transport, controller, store);
  } finally {
    controller.dispose();
    await store.outbox();
    await store.flagOutbox();
    await Future<void>.sync(client.dispose);
  }
}

// Hold only the generated snapshot platform acknowledgement, leaving the
// real controller and serialized LocalReviewStore operations intact.
class _HeldSnapshotPlatform extends InMemorySharedPreferencesStore {
  _HeldSnapshotPlatform() : super.empty();
  final entered = Completer<void>();
  final release = Completer<void>();
  bool acknowledged = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains('recall_snapshot_v1') && !entered.isCompleted) {
      entered.complete();
      await release.future;
      final result = await super.setValue(valueType, key, value);
      acknowledged = result;
      return result;
    }
    return super.setValue(valueType, key, value);
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('snapshot readiness waits for the original platform ACK before offline refresh', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final native = _HeldSnapshotPlatform();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = native;
    try {
      await withGeneratedFlow((transport, controller, store) async {
        try {
          await controller.load();
          await native.entered.future.timeout(const Duration(seconds: 5));
          var ready = false;
          final readiness = syntheticNativeAwaitOnlineSnapshot(store).then((_) {
            ready = true;
          });
          await Future<void>.value();
          expect(ready, isFalse);
          expect(native.acknowledged, isFalse);
          native.open();
          await readiness.timeout(const Duration(seconds: 5));
          expect(native.acknowledged, isTrue);
          expect(await store.loadSnapshot(), isNotNull);
          transport.offlineReads = true;
          await controller.refresh();
          await syntheticNativePhaseOneRatingActions(controller);
          await controller.syncPending();
          expect(controller.state.current?.id, 2);
          expect((await store.outbox()).length, 1);
          expect(await store.loadSnapshot(), isNotNull);
        } finally {
          native.open();
        }
      });
    } finally {
      native.open();
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    }
  });
  test('actual default controller load includes generated ML deck without explicit selection', () async {
    await withGeneratedFlow((transport, controller, store) async {
      await controller.load();
      expect(controller.state.error, isNull);
      expect(controller.state.offline, isFalse);
      expect(controller.state.queue.length, 20);
      expect(controller.state.current?.id, 1);
      expect(await store.outbox(), isEmpty);
    });
  });
  test(
    'original phase1 actions keep one acknowledged event and advance once',
    () async {
      await withGeneratedFlow((transport, controller, store) async {
        await controller.load();
        await syntheticNativeAwaitOnlineSnapshot(store);
        transport.offlineReads = true;
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        expect(controller.state.current?.id, 1);
        await syntheticNativePhaseOneRatingActions(controller);
        await controller.syncPending();
        final pending = await store.outbox();
        expect(pending.length, 1);
        expect(pending.single['card_id'], 1);
        expect(controller.state.current?.id, 2);
        expect(controller.state.reviewedThisSession, 1);
        expect(store.lastEnqueueAckUs, greaterThanOrEqualTo(0));
        expect(transport.offlineAttempts, greaterThanOrEqualTo(1));
        expect(transport.accepted, isEmpty);
        expect(await store.loadSnapshot(), isNotNull);
      });
    },
  );
  test('second unrevealed call remains a production guard no-op', () async {
    await withGeneratedFlow((transport, controller, store) async {
      await controller.load();
      await syntheticNativeAwaitOnlineSnapshot(store);
      transport.offlineReads = true;
      await controller.refresh();
      await syntheticNativePhaseOneRatingActions(controller);
      expect(controller.state.showBack, isFalse);
      await controller.rate(Rating.good);
      expect((await store.outbox()).length, 1);
      expect(controller.state.current?.id, 2);
      expect(controller.state.reviewedThisSession, 1);
    });
  });
  test('real RecallApi parses filtered due rows and generated deck count responses', () async {
    await withGeneratedFlow((transport, controller, store) async {
      final queue = await controller.api.fetchQueue(includedDeckIds: {1});
      expect(queue.length, 20);
      expect(queue.first.id, 1);
      expect(queue.last.id, 20);
      final counts = await controller.api.fetchDeckCounts();
      expect(counts[1]?.due, 20);
      expect(counts[1]?.neu, 0);
      expect(transport.counts['cards_due'], greaterThanOrEqualTo(2));
    });
  });
  test('real RecallApi sees structured offline and lost ACK errors then parses idempotent success', () async {
    await withGeneratedFlow((transport, controller, store) async {
      final event = <String, dynamic>{
        ...syntheticPendingReview(0),
        'card_id': 1,
        'guid': 'synthetic-card-1',
        'client_id': 'invented-request-metadata-event',
      };
      await expectLater(
        controller.api.applyReview(event),
        throwsA(isA<PostgrestException>()),
      );
      expect(transport.offlineAttempts, 1);
      expect(transport.accepted, isEmpty);
      transport.onlineWrites = true;
      transport.loseNextAck = true;
      await expectLater(
        controller.api.applyReview(event),
        throwsA(isA<PostgrestException>()),
      );
      expect(transport.accepted.length, 1);
      expect(await controller.api.applyReview(event), 9001);
      expect(transport.onlineAttempts, 2);
      expect(transport.accepted.length, 1);
      expect(transport.receivedHashes, [
        transport.eventHash('invented-request-metadata-event'),
        transport.eventHash('invented-request-metadata-event'),
      ]);
    });
  });
  test('actual generated helper refuses unsupported HEAD rather than yielding empty JSON', () async {
    final transport = SyntheticNativeOfflineHttp(
      List.generate(20, (i) => syntheticCard(i + 1)),
      'invented-owner-hash',
    );
    final uri = Uri.https('recall-bench.invalid', '/rest/v1/cards', {
      'select': '*',
      'state': 'neq.0',
      'deleted': 'eq.false',
      'suspended': 'eq.false',
      'order': 'due.asc.nullslast,id.asc.nullslast',
      'notes.deck_id': 'in.(1)',
    });
    await expectLater(
      transport.respond(http.Request('HEAD', uri)),
      throwsStateError,
    );
    final response = await transport.respond(http.Request('GET', uri));
    expect(response.statusCode, 200);
    expect(transport.counts['cards_due'], 1);
  });
}

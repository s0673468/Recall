import 'dart:async';
import 'dart:convert';

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
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

import 'support/recall_acceptance_fixture.dart';

// Entirely invented account, cards, and HTTP responses. The .invalid client
// uses MockClient, so neither sign-in nor review delivery can reach a server.
final _now = DateTime.utc(2026, 10, 14, 12);
const _ownerId = 'sanitized-learner-example-invalid';
const _otherOwnerId = 'synthetic-other-owner';
const _waitLimit = Duration(seconds: 5);

ReviewCard _card(int id) => ReviewCard(
  id: id,
  guid: 'invented-airplane-$id',
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
);

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

// Hold the platform acknowledgement, not LocalReviewStore's implementation.
// This is an in-memory native stand-in; a successful setValue is its durable ack.
class _NativePrefs extends InMemorySharedPreferencesStore {
  _NativePrefs() : super.empty();

  _Gate? nextReviewWrite;
  final acknowledgedReviewWrites = <List<Map<String, dynamic>>>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final reviewOutbox = key.contains('recall_outbox_v1');
    if (reviewOutbox) {
      final gate = nextReviewWrite;
      nextReviewWrite = null;
      if (gate != null) await gate.hold();
    }
    final written = await super.setValue(valueType, key, value);
    if (reviewOutbox && written) {
      acknowledgedReviewWrites.add([
        for (final entry in jsonDecode(value as String) as List)
          Map<String, dynamic>.from(entry as Map),
      ]);
    }
    return written;
  }
}

// The transport models one accepted RPC whose first response is lost. It
// records the authenticated bearer and the actual RecallApi RPC body.
class _Transport {
  bool online = false;
  bool loseNextAck = false;
  int offlineRpcAttempts = 0;
  final connectedRequests = <http.Request>[];
  final acceptedEventIds = <String, int>{};

  late final SupabaseClient client = SupabaseClient(
    'https://offline-roundtrip.invalid',
    'invented-anon-key',
    httpClient: MockClient(_reply),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  Future<http.Response> _reply(http.Request request) async {
    if (request.url.path.endsWith('/token')) {
      return http.Response(
        jsonEncode({
          'access_token': 'invented-owner-a-token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'invented-refresh',
          'user': {
            'id': _ownerId,
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': 'learner@example.invalid',
            'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
            'created_at': _now.toIso8601String(),
            'updated_at': _now.toIso8601String(),
          },
        }),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }
    if (!request.url.path.endsWith('/rpc/apply_review')) {
      throw StateError('Unexpected invented HTTP request: ${request.url.path}');
    }
    if (!online) {
      offlineRpcAttempts++;
      throw http.ClientException('invented airplane mode', request.url);
    }

    connectedRequests.add(request);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final eventId = body['p_client_event_id'] as String;
    final id = acceptedEventIds.putIfAbsent(eventId, () => 9001);
    if (loseNextAck) {
      loseNextAck = false;
      return http.Response(
        jsonEncode({'code': 'PGRST500', 'message': 'invented lost ack'}),
        503,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      '$id',
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

class _Api extends SanitizedRecallApi {
  _Api(this.transport)
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [_card(101), _card(102)],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  final _Transport transport;
  final _mirroredEventIds = <String>{};

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    // Keep the production RPC serializer and error handling in this path.
    final id = await RecallApi(transport.client).applyReview(entry);
    // The fixture owns queue reads. Mirror only an acknowledged event there.
    if (_mirroredEventIds.add(entry['client_id'] as String)) {
      await super.applyReview(entry);
    }
    return id;
  }
}

ReviewController _controller(_Api api, LocalReviewStore store) =>
    ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      haptics: const ReviewHaptics(),
      clock: () => _now,
    );

Future<T> _bounded<T>(Future<T> future) => future.timeout(_waitLimit);

void main() {
  test(
    'offline rating survives native ack and restart, then retries one RPC event',
    () async {
      final previousPlatform = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      final native = _NativePrefs();
      SharedPreferencesStorePlatform.instance = native;
      final transport = _Transport();
      final api = _Api(transport);
      final firstStore = LocalReviewStore();
      final firstController = _controller(api, firstStore);
      var firstControllerDisposed = false;
      LocalReviewStore? restartedStore;
      ReviewController? restartedController;
      final nativeAck = _Gate();
      addTearDown(() async {
        nativeAck.open();
        restartedController?.dispose();
        if (!firstControllerDisposed) firstController.dispose();
        try {
          await _bounded(firstStore.outbox());
          final second = restartedStore;
          if (second != null) await _bounded(second.outbox());
        } finally {
          api.disposeFixture();
          transport.client.dispose();
          SharedPreferencesStorePlatform.instance = previousPlatform;
          SharedPreferences.resetStatic();
        }
      });

      await _bounded(
        transport.client.auth.signInWithPassword(
          email: 'learner@example.invalid',
          password: 'invented-local-only',
        ),
      );
      expect(api.currentUser?.id, _ownerId);
      expect(transport.client.auth.currentUser?.id, _ownerId);
      await _bounded(firstStore.activateOwner(_ownerId));
      await _bounded(
        firstStore.saveSnapshot(
          decks: api.dataset.decks,
          queue: api.dataset.cards,
          globalDueCount: 2,
          globalDueUpdatedAt: _now,
        ),
      );
      await _bounded(firstController.load());
      expect(firstController.state.current?.id, 101);

      // Simulate airplane mode at both the read fixture and the RPC transport.
      api.online = false;
      await _bounded(firstController.refresh());
      expect(firstController.state.offline, isTrue);
      firstController.flip();
      native.nextReviewWrite = nativeAck;
      final rating = firstController.rate(Rating.good);
      await _bounded(nativeAck.entered.future);
      expect(firstController.state.current?.id, 101);
      expect(firstController.state.reviewedThisSession, 0);
      expect(native.acknowledgedReviewWrites, isEmpty);
      nativeAck.open();
      await _bounded(rating);

      final pending = await _bounded(firstStore.outbox());
      expect(pending, hasLength(1));
      final eventId = pending.single['client_id'] as String;
      expect(eventId, isNotEmpty);
      expect(pending.single['card_id'], 101);
      expect(pending.single['delivery_attempted'], isFalse);
      expect(native.acknowledgedReviewWrites.last.single['client_id'], eventId);
      expect(firstController.state.current?.id, 102);
      expect(firstController.state.reviewedThisSession, 1);
      expect(firstController.state.pendingSync, 1);
      expect(firstController.canUndo, isTrue);
      expect(transport.connectedRequests, isEmpty);

      // A fresh store and controller read the same native backend. A different
      // owner must not inherit this snapshot or outbox.
      firstController.dispose();
      firstControllerDisposed = true;
      SharedPreferences.resetStatic();
      final secondStore = LocalReviewStore();
      restartedStore = secondStore;
      await _bounded(secondStore.activateOwner(_otherOwnerId));
      expect(await _bounded(secondStore.outbox()), isEmpty);
      expect(await _bounded(secondStore.loadSnapshot()), isNull);
      await _bounded(secondStore.activateOwner(_ownerId));
      expect(
        (await _bounded(secondStore.outbox())).single['client_id'],
        eventId,
      );
      final secondController = _controller(api, secondStore);
      restartedController = secondController;
      await _bounded(secondController.load());
      expect(secondController.state.offline, isTrue);
      expect(secondController.state.current?.id, 102);
      expect(secondController.state.pendingSync, 1);
      expect(secondController.canUndo, isFalse);
      expect(
        (await _bounded(secondStore.outbox())).single['delivery_attempted'],
        isTrue,
      );
      expect(transport.offlineRpcAttempts, greaterThanOrEqualTo(1));

      api.online = true;
      transport.online = true;
      transport.loseNextAck = true;
      await _bounded(secondController.syncPending());
      expect(
        (await _bounded(secondStore.outbox())).single['client_id'],
        eventId,
      );
      expect(secondController.state.pendingSync, 1);
      expect(transport.acceptedEventIds, {eventId: 9001});

      await _bounded(secondController.syncPending());
      expect(await _bounded(secondStore.outbox()), isEmpty);
      expect(secondController.state.pendingSync, 0);
      expect(transport.connectedRequests, hasLength(2));
      for (final request in transport.connectedRequests) {
        expect(request.url.host, 'offline-roundtrip.invalid');
        expect(request.url.path, endsWith('/rpc/apply_review'));
        final authorization = request.headers.entries
            .singleWhere(
              (header) => header.key.toLowerCase() == 'authorization',
            )
            .value;
        expect(authorization, 'Bearer invented-owner-a-token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['p_client_event_id'], eventId);
        expect(body['p_card_id'], 101);
        expect(body['p_rating'], Rating.good.value);
        expect(body['p_guid'], 'invented-airplane-101');
        expect(body['p_device'], 'sanitized-local-web');
      }
      expect(transport.acceptedEventIds.length, 1);
      await _bounded(secondController.refresh());
      expect(secondController.state.current?.id, 102);
      expect(secondController.state.offline, isFalse);
    },
  );
}

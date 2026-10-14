import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

// Only the auth event stream is silenced. The tested RPC, controller flush, and
// durable outbox are their production implementations, with an unscoped unit
// store as supported by ReviewController._flushStillOwnsSession.
class _QuietAuthRecallApi extends RecallApi {
  const _QuietAuthRecallApi(super.client);

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const entry = <String, dynamic>{
    'card_id': 42,
    'guid': 'invented-guid',
    'stability': 2.5,
    'difficulty': 4.0,
    'due': '2026-07-14T12:00:00.000Z',
    'state': 2,
    'reps': 3,
    'lapses': 0,
    'last_review': '2026-07-13T12:34:56.789Z',
    'rating': 3,
    'elapsed_ms': 4000,
    'device': 'android',
    'client_id': 'invented-ambiguous-ack-1',
  };

  for (final response in <({String name, String body, bool retain})>[
    (name: 'null', body: 'null', retain: true),
    (name: 'fractional number', body: '1.5', retain: true),
    (name: 'boolean', body: 'true', retain: true),
    (name: 'object', body: '{"id":77}', retain: true),
    (name: 'zero integer', body: '0', retain: false),
    (name: 'negative integer', body: '-7', retain: false),
  ]) {
    test('${response.name} RPC ACK has the correct outbox effect', () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <http.BaseRequest>[];
      final client = SupabaseClient(
        'https://recall-fixture.invalid',
        'invented-public-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            response.body,
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final store = LocalReviewStore();
      await store.enqueueReview(entry);
      final controller = ReviewController(
        api: _QuietAuthRecallApi(client),
        engine: FsrsEngine(),
        store: store,
        haptics: const ReviewHaptics(),
      );
      addTearDown(controller.dispose);

      await controller.syncPending();

      expect(requests, hasLength(1));
      final request = requests.single as http.Request;
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/rpc/apply_review'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['p_client_event_id'], entry['client_id']);
      final pending = await store.outbox();
      if (response.retain) {
        expect(pending, hasLength(1));
        expect(pending.single['client_id'], entry['client_id']);
        expect(pending.single['delivery_attempted'], isTrue);
      } else {
        expect(pending, isEmpty);
      }
    });
  }

  test(
    'retry after ambiguous ACK sends the original event once more',
    () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <http.BaseRequest>[];
      final client = SupabaseClient(
        'https://recall-fixture.invalid',
        'invented-public-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            requests.length == 1 ? 'null' : '77',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final store = LocalReviewStore();
      await store.enqueueReview(entry);
      final controller = ReviewController(
        api: _QuietAuthRecallApi(client),
        engine: FsrsEngine(),
        store: store,
        haptics: const ReviewHaptics(),
      );
      addTearDown(controller.dispose);

      await controller.syncPending();
      final stillQueued = await store.outbox();
      expect(stillQueued, hasLength(1));
      expect(stillQueued.single['client_id'], entry['client_id']);
      expect(stillQueued.single['delivery_attempted'], isTrue);

      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      await controller.syncPending();
      expect(requests, hasLength(2));
      for (final request in requests.cast<http.Request>()) {
        expect(request.url.path, endsWith('/rpc/apply_review'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['p_client_event_id'], entry['client_id']);
      }
    },
  );
}

import 'dart:async';

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

class _QuietAuthRecallApi extends RecallApi {
  const _QuietAuthRecallApi(super.client);

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();
}

enum _AckStage { eventLookup, legacyLookup, upsert, insert }

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
    'client_id': 'invented-legacy-ack-1',
  };

  for (final stage in _AckStage.values) {
    for (final badId in <({String label, String json})>[
      (label: 'null', json: 'null'),
      (label: 'fractional', json: '1.5'),
    ]) {
      test(
        'legacy ${stage.name} ${badId.label} ID retains attempted review',
        () async {
          SharedPreferences.setMockInitialValues({});
          final requests = <http.BaseRequest>[];
          var reviewLogReads = 0;
          final client = SupabaseClient(
            'https://recall-fixture.invalid',
            'invented-public-key',
            httpClient: MockClient((request) async {
              requests.add(request);
              final path = request.url.path;
              http.Response json(String body, {int status = 200}) =>
                  http.Response(
                    body,
                    status,
                    request: request,
                    headers: {'content-type': 'application/json'},
                  );
              if (path.endsWith('/rpc/apply_review')) {
                return json(
                  '{"code":"PGRST202","message":"invented absent RPC"}',
                  status: 404,
                );
              }
              if (request.method == 'GET' && path.endsWith('/review_log')) {
                reviewLogReads++;
                final needsLegacy =
                    stage == _AckStage.legacyLookup ||
                    stage == _AckStage.insert;
                if (needsLegacy && reviewLogReads == 1) {
                  return json(
                    '{"code":"42703","message":"invented missing column"}',
                    status: 400,
                  );
                }
                final hasMalformedLookup =
                    stage == _AckStage.eventLookup ||
                    stage == _AckStage.legacyLookup;
                return json(
                  hasMalformedLookup ? '[{"id":${badId.json}}]' : '[]',
                );
              }
              if (request.method == 'GET' && path.endsWith('/cards')) {
                return json(
                  '{"reps":3,"lapses":1,'
                  '"last_review":"2026-07-01T00:00:00.000Z"}',
                );
              }
              if (request.method == 'PATCH' && path.endsWith('/cards')) {
                return json('[{"id":42}]');
              }
              if (request.method == 'POST' && path.endsWith('/review_log')) {
                return json('{"id":${badId.json}}', status: 201);
              }
              throw StateError('Unexpected invented fixture request');
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

          final expectedMethods = switch (stage) {
            _AckStage.eventLookup => ['POST', 'GET'],
            _AckStage.legacyLookup => ['POST', 'GET', 'GET'],
            _AckStage.upsert => ['POST', 'GET', 'GET', 'PATCH', 'POST'],
            _AckStage.insert => ['POST', 'GET', 'GET', 'GET', 'PATCH', 'POST'],
          };
          expect(requests.map((request) => request.method), expectedMethods);
          expect(requests.first.url.path, endsWith('/rpc/apply_review'));
          expect(
            requests.where((request) => request.method == 'PATCH'),
            hasLength(
              stage == _AckStage.upsert || stage == _AckStage.insert ? 1 : 0,
            ),
          );
          final pending = await store.outbox();
          expect(pending, hasLength(1));
          expect(pending.single['client_id'], entry['client_id']);
          expect(pending.single['delivery_attempted'], isTrue);
        },
      );
    }
  }
}

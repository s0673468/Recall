import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  RecallApi api(Future<http.Response> Function(http.Request) respond) {
    final client = SupabaseClient(
      'https://synthetic.invalid',
      'synthetic-placeholder',
      httpClient: MockClient(respond),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return RecallApi(client);
  }

  http.Response jsonResponse(http.Request request, Object value) =>
      http.Response(
        jsonEncode(value),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );

  test(
    'open likes paginate by flag id without mixing hidden reasons',
    () async {
      final requests = <Uri>[];
      final remote = api((request) async {
        requests.add(request.url);
        final cursor = request.url.queryParameters['id'];
        return jsonResponse(
          request,
          cursor == null
              ? [
                  {'id': 7, 'card_id': 2, 'client_event_id': 'synthetic-like'},
                ]
              : [],
        );
      });
      expect(await remote.fetchLikedFlags(), [
        {'card_id': 2, 'client_id': 'synthetic-like', 'reason': 'like'},
      ]);
      expect(requests, hasLength(2));
      expect(requests.last.queryParameters['id'], 'gt.7');
      for (final uri in requests) {
        expect(uri.queryParameters['status'], 'eq.open');
        expect(uri.queryParameters['reason'], 'eq.like');
        expect(uri.queryParameters['select'], 'id,card_id,client_event_id');
        expect(uri.queryParameters['order'], startsWith('id.asc'));
      }
    },
  );

  test(
    'a repeated likes page is rejected instead of returning partial truth',
    () async {
      final remote = api(
        (request) async => jsonResponse(request, [
          {'id': 1, 'card_id': 2, 'client_event_id': 'synthetic-like'},
        ]),
      );
      await expectLater(remote.fetchLikedFlags(), throwsStateError);
    },
  );

  test(
    'like uses the normal idempotent insert and exact-id withdrawal',
    () async {
      final requests = <http.Request>[];
      final remote = api((request) async {
        requests.add(request);
        return jsonResponse(request, []);
      });
      await remote.applyFlag({
        'card_id': 2,
        'guid': 'synthetic-guid',
        'reason': 'like',
        'flagged_at': '2026-10-01T00:00:00Z',
        'device': 'test',
        'client_id': 'synthetic-like',
      });
      await remote.dismissFlag(cardId: 2, clientEventId: 'synthetic-like');
      final insert = requests.first;
      expect(jsonDecode(insert.body)['reason'], 'like');
      expect(jsonDecode(insert.body)['client_event_id'], 'synthetic-like');
      expect(
        insert.url.queryParameters['on_conflict'],
        'card_id,client_event_id',
      );
      expect(
        insert.headers['prefer'],
        contains('resolution=ignore-duplicates'),
      );
      final dismiss = requests.last;
      expect(dismiss.method, 'PATCH');
      expect(
        dismiss.url.queryParameters['client_event_id'],
        'eq.synthetic-like',
      );
      expect(dismiss.url.queryParameters['card_id'], 'eq.2');
      expect(dismiss.url.queryParameters['status'], 'eq.open');
      expect(jsonDecode(dismiss.body)['status'], 'dismissed');
    },
  );
}

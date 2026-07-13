import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  const entry = <String, dynamic>{
    'card_id': 42,
    'guid': 'g42',
    'stability': 2.5,
    'difficulty': 4.0,
    'due': '2026-07-14T12:00:00.000Z',
    'state': 2,
    'reps': 3,
    'lapses': 0,
    'last_review': '2026-07-13T12:34:56.789Z',
    'rating': 3,
    'elapsed_ms': 4000,
    'device': 'ios',
    'client_id': 'event-42-1',
  };

  test('a replay returns the existing log without applying twice', () async {
    final requests = <http.BaseRequest>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.method == 'PATCH') {
          return http.Response('', 204, request: request);
        }
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode([
              {'id': 77},
            ]),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'id': 77}),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);

    final id = await RecallApi(client).applyReview(entry);

    expect(id, 77);
    expect(requests, hasLength(1));
    final query = requests.single.url.query;
    expect(query, contains('card_id=eq.42'));
    expect(query, contains('client_event_id=eq.event-42-1'));
  });

  test('a new review still updates the card and inserts one log', () async {
    final requests = <http.BaseRequest>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 88}),
            201,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PATCH') {
          return http.Response('', 204, request: request);
        }
        return http.Response('[]', 200, request: request);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);

    final id = await RecallApi(client).applyReview(entry);

    expect(id, 88);
    expect(requests.map((request) => request.method), ['GET', 'PATCH', 'POST']);
    final insert = requests.last;
    expect(insert.url.query, contains('on_conflict=card_id%2Cclient_event_id'));
    expect(
      jsonDecode((insert as http.Request).body),
      containsPair('client_event_id', 'event-42-1'),
    );
  });

  test('flag replay upserts with the durable client event id', () async {
    final requests = <http.BaseRequest>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('', 201, request: request);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);

    await RecallApi(client).applyFlag({
      'card_id': 42,
      'guid': 'g42',
      'reason': 'confusing',
      'flagged_at': '2026-07-13T12:34:56.789Z',
      'device': 'ios',
      'client_id': 'flag-42-1',
    });

    expect(requests, hasLength(1));
    final request = requests.single as http.Request;
    expect(
      request.url.query,
      contains('on_conflict=card_id%2Cclient_event_id'),
    );
    expect(request.headers['prefer'], contains('resolution=ignore-duplicates'));
    expect(
      jsonDecode(request.body),
      containsPair('client_event_id', 'flag-42-1'),
    );
  });
}

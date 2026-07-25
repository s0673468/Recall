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

  test('a new review reads server state, guards the write, and logs', () async {
    final requests = <http.BaseRequest>[];
    http.Response json(String body, {int status = 200, http.BaseRequest? to}) =>
        http.Response(
          body,
          status,
          request: to,
          headers: {'content-type': 'application/json'},
        );
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (request.method == 'GET' && path.endsWith('review_log')) {
          return json('[]', to: request); // no prior replay of this event
        }
        if (request.method == 'GET' && path.endsWith('cards')) {
          // Server truth: three reps and one lapse, last reviewed 2026-07-01.
          return json(
            jsonEncode({
              'reps': 3,
              'lapses': 1,
              'last_review': '2026-07-01T00:00:00.000Z',
            }),
            to: request,
          );
        }
        if (request.method == 'PATCH') {
          return json(jsonEncode([
            {'id': 42},
          ]), to: request);
        }
        if (request.method == 'POST') {
          return json(jsonEncode({'id': 88}), status: 201, to: request);
        }
        return json('[]', to: request);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);

    final id = await RecallApi(client).applyReview(entry);

    expect(id, 88);
    // Dedup probe, card read, guarded merge, log append.
    expect(requests.map((request) => request.method), [
      'GET',
      'GET',
      'PATCH',
      'POST',
    ]);

    final patch = requests[2];
    expect(patch.url.query, contains('id=eq.42'));
    // Compare-and-swap: the merge only lands while `reps` is still the value
    // it was computed from.
    expect(patch.url.query, contains('reps=eq.3'));
    final patched = jsonDecode((patch as http.Request).body);
    // Counters come from the server (3 + 1), never the entry's stale absolute
    // `reps: 3` — that is what a second device's review would have clobbered.
    expect(patched, containsPair('reps', 4));
    expect(patched, containsPair('lapses', 1)); // a Good rating is no lapse
    // This review is newer than the row, so it also owns the scheduling.
    expect(patched, containsPair('due', '2026-07-14T12:00:00.000Z'));

    final insert = requests.last;
    expect(insert.url.query, contains('on_conflict=card_id%2Cclient_event_id'));
    expect(
      jsonDecode((insert as http.Request).body),
      containsPair('client_event_id', 'event-42-1'),
    );
  });

  test('a review older than the card keeps its rep but not the schedule', () async {
    final requests = <http.BaseRequest>[];
    http.Response json(String body, {int status = 200, http.BaseRequest? to}) =>
        http.Response(
          body,
          status,
          request: to,
          headers: {'content-type': 'application/json'},
        );
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (request.method == 'GET' && path.endsWith('review_log')) {
          return json('[]', to: request);
        }
        if (request.method == 'GET' && path.endsWith('cards')) {
          // Another device already synced a *later* review of this card.
          return json(
            jsonEncode({
              'reps': 9,
              'lapses': 2,
              'last_review': '2026-07-20T08:00:00.000Z',
            }),
            to: request,
          );
        }
        if (request.method == 'PATCH') {
          return json(jsonEncode([
            {'id': 42},
          ]), to: request);
        }
        return json(jsonEncode({'id': 90}), status: 201, to: request);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);

    await RecallApi(client).applyReview(entry);

    final patched =
        jsonDecode((requests[2] as http.Request).body) as Map<String, dynamic>;
    expect(patched, containsPair('reps', 10)); // the review still counts
    // …but none of the scheduling columns are touched, so the newer device's
    // due date survives.
    expect(patched.keys, isNot(contains('due')));
    expect(patched.keys, isNot(contains('stability')));
    expect(patched.keys, isNot(contains('last_review')));
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

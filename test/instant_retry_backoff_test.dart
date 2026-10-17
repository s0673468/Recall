import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/instant_retry_backoff.dart';

void main() {
  SupabaseClient unavailable(List<http.Request> requests) => SupabaseClient(
    'https://example.supabase.co',
    'anon-key',
    httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({'message': 'unavailable'}),
        503,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  test('every postgrest retry still runs, without the backoff sleeps', () async {
    final requests = <http.Request>[];
    final client = unavailable(requests);
    addTearDown(client.dispose);

    final clock = Stopwatch()..start();
    await withInstantRetryBackoff(
      () => expectLater(
        client.from('cards').select(),
        throwsA(isA<PostgrestException>()),
      ),
    );
    clock.stop();

    // One attempt plus postgrest's three retries; the real backoff is 7 s.
    expect(requests, hasLength(4));
    expect(
      [for (final r in requests) r.headers['X-Retry-Count']],
      [null, '1', '2', '3'],
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('other timers keep their real duration', () async {
    final clock = Stopwatch()..start();
    await withInstantRetryBackoff(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    clock.stop();
    expect(clock.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 200)));

    final timeout = withInstantRetryBackoff(
      () => Completer<void>().future.timeout(const Duration(milliseconds: 50)),
    );
    await expectLater(timeout, throwsA(isA<TimeoutException>()));
  });

  test('writes are not retried, so nothing changes for them', () async {
    final requests = <http.Request>[];
    final client = unavailable(requests);
    addTearDown(client.dispose);

    await withInstantRetryBackoff(
      () => expectLater(
        client.from('review_log').insert({'card_id': 1}),
        throwsA(isA<PostgrestException>()),
      ),
    );
    expect(requests, hasLength(1));
  });
}

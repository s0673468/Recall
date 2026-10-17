import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

// Europe/Berlin in 2026: summer time runs from 2026-03-29T01:00Z to
// 2026-10-25T01:00Z. Local midnights move between UTC+1 and UTC+2, so the
// spring-forward day is 23 hours long and the fall-back day is 25 hours.
DateTime _berlinMidnight(int year, int month, int day) {
  final wall = DateTime.utc(year, month, day);
  final summer =
      wall.isAfter(DateTime.utc(2026, 3, 29)) &&
      !wall.isAfter(DateTime.utc(2026, 10, 25));
  return wall.subtract(Duration(hours: summer ? 2 : 1));
}

void main() {
  group('injected Europe/Berlin calendar', () {
    test('fall-back day counts introductions in its 25th hour', () async {
      final fixture = _Fixture([
        // 00:30 CEST, the first hour of 25 October.
        (1, 41, DateTime.utc(2026, 10, 24, 22, 30)),
        // 23:30 CET, the last hour of 25 October.
        (2, 42, DateTime.utc(2026, 10, 25, 22, 30)),
        // 00:30 CET on 26 October belongs to the next day.
        (3, 43, DateTime.utc(2026, 10, 25, 23, 30)),
      ]);
      final client = fixture.client();
      addTearDown(client.dispose);

      await RecallApi(
        client,
        localNow: () => DateTime(2026, 10, 25, 23, 30),
        localMidnight: _berlinMidnight,
      ).fetchQueue(newLimit: 10);

      expect(fixture.newLimit, 8);
      fixture.expectWindow(
        '2026-10-24T22:00:00.000Z',
        '2026-10-25T23:00:00.000Z',
      );
    });

    test('spring-forward day ends at the next local midnight', () async {
      final fixture = _Fixture([
        // 23:30 CEST, the last hour of 29 March.
        (1, 41, DateTime.utc(2026, 3, 29, 21, 30)),
        // 00:30 CEST on 30 March belongs to the next day.
        (2, 42, DateTime.utc(2026, 3, 29, 22, 30)),
      ]);
      final client = fixture.client();
      addTearDown(client.dispose);

      await RecallApi(
        client,
        localNow: () => DateTime(2026, 3, 29, 23, 30),
        localMidnight: _berlinMidnight,
      ).fetchQueue(newLimit: 10);

      expect(fixture.newLimit, 9);
      fixture.expectWindow(
        '2026-03-28T23:00:00.000Z',
        '2026-03-29T22:00:00.000Z',
      );
    });

    for (final (now, start, end) in [
      (
        DateTime(2026, 3, 28, 12),
        '2026-03-27T23:00:00.000Z',
        '2026-03-28T23:00:00.000Z',
      ),
      (
        DateTime(2026, 3, 30, 12),
        '2026-03-29T22:00:00.000Z',
        '2026-03-30T22:00:00.000Z',
      ),
      (
        DateTime(2026, 10, 24, 12),
        '2026-10-23T22:00:00.000Z',
        '2026-10-24T22:00:00.000Z',
      ),
      (
        DateTime(2026, 10, 26, 12),
        '2026-10-25T23:00:00.000Z',
        '2026-10-26T23:00:00.000Z',
      ),
    ]) {
      test(
        'ordinary day ${now.month}/${now.day} keeps a 24-hour window',
        () async {
          final fixture = _Fixture([(1, 41, DateTime.parse(start))]);
          final client = fixture.client();
          addTearDown(client.dispose);

          await RecallApi(
            client,
            localNow: () => now,
            localMidnight: _berlinMidnight,
          ).fetchQueue(newLimit: 10);

          expect(fixture.newLimit, 9);
          fixture.expectWindow(start, end);
        },
      );
    }
  });

  // These use the process time zone. Run them with TZ=Europe/Berlin as well as
  // the default zone to exercise the platform calendar on transition days.
  group('host calendar', () {
    for (final now in [
      DateTime(2026, 3, 29, 23, 30),
      DateTime(2026, 10, 25, 23, 30),
      DateTime(2026, 10, 24, 12),
    ]) {
      test(
        '${now.month}/${now.day} spans local midnight to midnight',
        () async {
          final start = DateTime(now.year, now.month, now.day);
          final end = DateTime(now.year, now.month, now.day + 1);
          final fixture = _Fixture([
            (1, 41, start),
            (2, 42, end.subtract(const Duration(minutes: 30))),
            (3, 43, end),
          ]);
          final client = fixture.client();
          addTearDown(client.dispose);

          await RecallApi(client, localNow: () => now).fetchQueue(newLimit: 10);

          expect(fixture.newLimit, 8);
          fixture.expectWindow(
            start.toUtc().toIso8601String(),
            end.toUtc().toIso8601String(),
          );
        },
      );
    }
  });
}

class _Fixture {
  final List<(int, int, DateTime)> rows;
  final List<Uri> requests = [];

  _Fixture(this.rows);

  List<Uri> get todayRequests => [
    for (final uri in requests)
      if (uri.path.endsWith('/review_log') &&
          !uri.queryParameters.containsKey('card_id'))
        uri,
  ];

  int? get newLimit {
    final matches = requests.where(
      (uri) =>
          uri.path.endsWith('/cards') && uri.queryParameters['state'] == 'eq.0',
    );
    return matches.isEmpty
        ? null
        : int.parse(matches.single.queryParameters['limit']!);
  }

  void expectWindow(String start, String end) {
    expect(todayRequests, isNotEmpty);
    for (final uri in todayRequests) {
      expect(uri.queryParametersAll['rating_at'], ['gte.$start', 'lt.$end']);
    }
  }

  SupabaseClient client() => SupabaseClient(
    'https://recall-dst-day-fixture.invalid',
    'invented-anon-key',
    httpClient: MockClient((request) async {
      requests.add(request.url);
      if (!request.url.path.endsWith('/review_log')) {
        return _response(request, const []);
      }
      final query = request.url.queryParameters;
      final cursor = query['id'];
      final cards = query['card_id'];
      final matching = [
        for (final (id, cardId, at) in rows)
          if (_inWindow(at, request.url.queryParametersAll['rating_at']) &&
              (cursor == null || id > int.parse(cursor.substring(3))) &&
              (cards == null || _inIds(cards).contains(cardId)))
            {'id': id, 'card_id': cardId},
      ];
      return _response(request, matching);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

bool _inWindow(DateTime at, List<String>? filters) {
  for (final filter in filters ?? const <String>[]) {
    if (filter.startsWith('gte.') &&
        at.isBefore(DateTime.parse(filter.substring(4)))) {
      return false;
    }
    if (filter.startsWith('lt.') &&
        !at.isBefore(DateTime.parse(filter.substring(3)))) {
      return false;
    }
  }
  return true;
}

Set<int> _inIds(String filter) =>
    filter.substring(4, filter.length - 1).split(',').map(int.parse).toSet();

http.Response _response(
  http.Request request,
  List<Map<String, dynamic>> rows,
) => http.Response(
  jsonEncode(rows),
  200,
  request: request,
  headers: {'content-type': 'application/json'},
);

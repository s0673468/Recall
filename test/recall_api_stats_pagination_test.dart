import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  test('production-scale Stats inputs page past the server row cap', () async {
    var reviewPage = 0;
    var notesPage = 0;
    var duePage = 0;
    final cursorQueries = <Uri>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.url.queryParameters.containsKey('or') ||
            request.url.queryParameters.containsKey('guid')) {
          cursorQueries.add(request.url);
        }
        late final List<Map<String, dynamic>> rows;
        if (path.endsWith('/review_log')) {
          reviewPage++;
          rows = switch (reviewPage) {
            1 => [for (var i = 0; i < 500; i++) _reviewRow(i)],
            2 => [_reviewRow(500)],
            _ => const <Map<String, dynamic>>[],
          };
        } else if (path.endsWith('/notes')) {
          notesPage++;
          rows = switch (notesPage) {
            1 => [for (var i = 0; i < 500; i++) _noteRow(i)],
            2 => [_noteRow(500)],
            _ => const <Map<String, dynamic>>[],
          };
        } else if (path.endsWith('/cards')) {
          duePage++;
          rows = switch (duePage) {
            1 => [for (var i = 0; i < 500; i++) _dueRow(i)],
            2 => [_dueRow(500)],
            _ => const <Map<String, dynamic>>[],
          };
        } else {
          rows = const [];
        }
        return http.Response(
          jsonEncode(rows),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final api = RecallApi(client);

    final reviews = await api.fetchReviewLog();
    final tags = await api.fetchNoteTags();
    final dueDates = await api.fetchDueDates();

    expect(reviews, hasLength(501));
    expect(tags, hasLength(501));
    expect(dueDates, hasLength(501));
    expect(reviewPage, 3);
    expect(notesPage, 3);
    expect(duePage, 3);
    expect(cursorQueries, hasLength(6));
    expect(
      cursorQueries.any(
        (uri) => (uri.queryParameters['or'] ?? '').contains('rating_at.gt.'),
      ),
      isTrue,
    );
    expect(
      cursorQueries.any((uri) => uri.queryParameters['guid'] == 'gt.guid-0499'),
      isTrue,
    );
    expect(
      cursorQueries.any(
        (uri) => (uri.queryParameters['or'] ?? '').contains('id.gt.499'),
      ),
      isTrue,
    );
  });

  test(
    'Stats keep paging when the server caps pages below the requested size',
    () async {
      const total = 600, cap = 250;
      final pages = <String, int>{};
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: MockClient((request) async {
          final table = request.url.pathSegments.last;
          final page = pages.update(table, (n) => n + 1, ifAbsent: () => 1);
          final start = (page - 1) * cap;
          final ids = [
            for (var i = start; i < total && i < start + cap; i++) i,
          ];
          final rows = switch (table) {
            'review_log' => [for (final i in ids) _reviewRow(i)],
            'notes' => [for (final i in ids) _noteRow(i)],
            'cards' => [for (final i in ids) _dueRow(i)],
            _ => const <Map<String, dynamic>>[],
          };
          return http.Response(
            jsonEncode(rows),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final api = RecallApi(client);

      expect(await api.fetchReviewLog(), hasLength(total));
      expect(await api.fetchNoteTags(), hasLength(total));
      expect(await api.fetchDueDates(), hasLength(total));
      expect(pages, {'review_log': 4, 'notes': 4, 'cards': 4});
    },
  );

  test(
    'note tags follow server collation across mixed-case page boundaries',
    () async {
      final pages = <List<Map<String, dynamic>>>[
        [
          for (var i = 0; i < 499; i++)
            {'guid': 'a$i', 'tags': 'node::first-$i'},
          {'guid': 'mOSU9FNgyu', 'tags': 'node::first-end'},
        ],
        [
          for (var i = 0; i < 499; i++)
            {'guid': 'n$i', 'tags': 'node::second-$i'},
          {'guid': 'W3HUq4ElGI', 'tags': 'node::second-end'},
        ],
        [
          {'guid': 'z-last', 'tags': 'node::short-page'},
        ],
        [],
      ];
      final queries = <Uri>[];
      final client = _noteTagClient(pages, queries);
      addTearDown(client.dispose);

      final tags = await RecallApi(client).fetchNoteTags();

      expect(tags, {
        for (final page in pages)
          for (final row in page) row['guid'] as String: row['tags'] as String,
      });
      expect(tags, hasLength(1001));
      expect(queries.map((uri) => uri.queryParameters['guid']), [
        null,
        'gt.mOSU9FNgyu',
        'gt.W3HUq4ElGI',
        'gt.z-last',
      ]);
      for (final uri in queries) {
        expect(uri.queryParameters['order'], 'guid.asc.nullslast');
        expect(uri.queryParameters['limit'], '500');
      }
    },
  );

  test(
    'note tags reject a repeated last GUID instead of paging forever',
    () async {
      final queries = <Uri>[];
      final client = _noteTagClient([
        [
          {'guid': 'mOSU9FNgyu', 'tags': 'node::first'},
        ],
        [
          {'guid': 'mOSU9FNgyu', 'tags': 'node::repeated'},
        ],
        [],
      ], queries);
      addTearDown(client.dispose);

      await expectLater(
        RecallApi(client).fetchNoteTags(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Note-tag pagination did not advance',
          ),
        ),
      );
      expect(queries, hasLength(2));
      expect(queries.last.queryParameters['guid'], 'gt.mOSU9FNgyu');
    },
  );
}

Map<String, dynamic> _reviewRow(int id) {
  final at = DateTime.utc(2026, 8, 1).add(Duration(minutes: id));
  return {
    'id': id,
    'card_id': id + 1,
    'guid': 'guid-${id.toString().padLeft(4, '0')}',
    'rating_at': at.toIso8601String(),
    'rating': 3,
    'state_after': 2,
    'due_after': at.add(const Duration(days: 7)).toIso8601String(),
  };
}

Map<String, dynamic> _noteRow(int id) => {
  'guid': 'guid-${id.toString().padLeft(4, '0')}',
  'tags': 'node::concept-${id % 72}',
};

Map<String, dynamic> _dueRow(int id) => {
  'id': id,
  'due': DateTime.utc(2026, 9, 1).add(Duration(minutes: id)).toIso8601String(),
};

SupabaseClient _noteTagClient(
  List<List<Map<String, dynamic>>> pages,
  List<Uri> queries,
) => SupabaseClient(
  'https://example.supabase.co',
  'anon-key',
  httpClient: MockClient((request) async {
    queries.add(request.url);
    final index = queries.length - 1;
    return http.Response(
      jsonEncode(index < pages.length ? pages[index] : []),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }),
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

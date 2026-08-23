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
          rows = reviewPage == 1
              ? [for (var i = 0; i < 500; i++) _reviewRow(i)]
              : [_reviewRow(500)];
        } else if (path.endsWith('/notes')) {
          notesPage++;
          rows = notesPage == 1
              ? [for (var i = 0; i < 500; i++) _noteRow(i)]
              : [_noteRow(500)];
        } else if (path.endsWith('/cards')) {
          duePage++;
          rows = duePage == 1
              ? [for (var i = 0; i < 500; i++) _dueRow(i)]
              : [_dueRow(500)];
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
    expect(reviewPage, 2);
    expect(notesPage, 2);
    expect(duePage, 2);
    expect(cursorQueries, hasLength(3));
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

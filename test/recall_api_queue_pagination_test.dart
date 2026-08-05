import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

Map<String, dynamic> _dueRow(int id) => {
  'id': id,
  'guid': 'g$id',
  'stability': 10.0,
  'difficulty': 5.0,
  'due': DateTime.utc(2026, 8, 5, 11).toIso8601String(),
  'state': 2,
  'reps': 5,
  'lapses': 0,
  'last_review': DateTime.utc(2026, 8, 1).toIso8601String(),
  'cloud_seen': false,
  'notes': {
    'front': 'front$id',
    'back': 'back$id',
    'has_latex': false,
    'deck_id': 1,
    'latex_svg': null,
  },
};

void main() {
  test('fetchQueue pages past the existing 500-row due window', () async {
    var duePage = 0;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        List<Map<String, dynamic>> rows;
        if (path.endsWith('/cards') && request.url.query.contains('state=neq.0')) {
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

    final queue = await RecallApi(client).fetchQueue(newLimit: 20);

    expect(duePage, 2);
    expect(queue, hasLength(501));
    expect(queue.last.id, 500);
  });
}

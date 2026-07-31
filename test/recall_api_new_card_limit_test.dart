import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  test(
    'fetchQueue subtracts first-ever introductions from today\'s limit',
    () async {
      final requests = <http.BaseRequest>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/review_log')) {
            final rows = request.url.query.contains('card_id=in.')
                ? [
                    {'card_id': 2},
                  ]
                : [
                    {'card_id': 1},
                    {'card_id': 1},
                    {'card_id': 2},
                  ];
            return http.Response(
              jsonEncode(rows),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);

      final queue = await RecallApi(client).fetchQueue(newLimit: 20);

      expect(queue, isEmpty);
      final newRequest = requests.singleWhere(
        (request) =>
            request.url.path.endsWith('/cards') &&
            request.url.queryParameters['state'] == 'eq.0',
      );
      expect(
        newRequest.url.queryParameters['limit'],
        '19',
        reason: requests.map((request) => request.url).join('\n'),
      );
    },
  );
}

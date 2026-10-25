import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/data/list_feedback_api.dart';

void main() {
  for (final stalled in [false, true]) {
    test(
      'feedback metadata pages past short server pages (stalled=$stalled)',
      () async {
        final requests = <Uri>[];
        final client = SupabaseClient(
          'https://synthetic.invalid',
          '',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            requests.add(request.url);
            expect(request.method, 'GET');
            expect(request.url.path, '/rest/v1/note_flags');
            expect(
              request.url.queryParameters['select'],
              'id,card_id,guid,reason,client_event_id',
            );
            expect(request.url.queryParameters['status'], 'eq.open');
            expect(
              request.url.queryParameters['reason'],
              'in.("like","dislike")',
            );
            expect(request.url.queryParameters['order'], 'id.asc.nullslast');
            final rows = requests.length > 2
                ? []
                : [
                    {
                      'id': stalled ? 1 : requests.length,
                      'card_id':
                          10, // Pagination must not use repeated card IDs.
                      'guid': 'synthetic-note',
                      'reason': requests.length == 1 ? 'like' : 'dislike',
                      'client_event_id': 'synthetic-event-${requests.length}',
                    },
                  ];
            return http.Response(
              jsonEncode(rows),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(client.dispose);
        final loading = RecallApi(client).fetchListFeedbackFlags();
        if (stalled) {
          await expectLater(loading, throwsStateError);
          expect(requests, hasLength(2));
        } else {
          final result = await loading;
          expect(result, hasLength(2));
          expect(result.map((flag) => flag['reason']), ['like', 'dislike']);
          expect(result.first['client_id'], 'synthetic-event-1');
          expect(requests, hasLength(3));
          expect(requests[1].queryParameters['id'], 'gt.1');
          expect(requests[2].queryParameters['id'], 'gt.2');
        }
      },
    );
  }
}

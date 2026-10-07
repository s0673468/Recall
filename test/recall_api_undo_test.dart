import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  for (final signedIn in [false, true]) {
    for (final legacy in [false, true]) {
      test(
        'remote Undo refuses before transport (signedIn=$signedIn legacy=$legacy)',
        () async {
          final requests = <http.Request>[];
          final client = SupabaseClient(
            'https://example.supabase.co',
            'invented-anon',
            httpClient: MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/token')) {
                return http.Response(
                  jsonEncode({
                    'access_token': 'invented-access-token',
                    'refresh_token': 'invented-refresh-token',
                    'token_type': 'bearer',
                    'expires_in': 3600,
                    'user': {
                      'id': '00000000-0000-0000-0000-000000000001',
                      'aud': 'authenticated',
                      'role': 'authenticated',
                      'email': 'invented@example.invalid',
                      'created_at': '2026-10-07T00:00:00Z',
                    },
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              throw StateError(
                'Remote Undo must never reach any API transport',
              );
            }),
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          );
          addTearDown(client.dispose);
          final api = RecallApi(client);
          if (signedIn) {
            await api.signIn(
              email: 'invented@example.invalid',
              password: 'invented-password',
            );
          }
          requests.clear();
          final receipt = legacy
              ? <String, dynamic>{}
              : <String, dynamic>{
                  'card_id': 42,
                  'guid': 'invented-card',
                  'review_log_id': 77,
                  'client_id': 'invented-event',
                  'expected_reps': 4,
                  'expected_lapses': 1,
                  'expected_last_review': '2026-10-07T12:00:00Z',
                  'reps': 3,
                };
          for (var attempt = 0; attempt < 2; attempt++) {
            await expectLater(
              api.undoReview(receipt),
              throwsA(isA<UndoConflictException>()),
            );
          }
          expect(
            requests,
            isEmpty,
          ); // includes GET/RPC/PATCH/DELETE: all forbidden
          expect(
            const UndoConflictException().toString(),
            'Synced reviews cannot be undone',
          );
        },
      );
    }
  }
  test('policy marker states the never-attempted boundary', () {
    expect(RecallApi.syncedUndoPolicy, 'never-attempted-local-only-v1');
  });
}

/// Synthetic real-API pagination qualification. A lower transport cap is a
/// controlled configuration hypothesis, not a claim about deployed PostgREST.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

Map<String, dynamic> _syntheticDueRow(int id) => {
  'id': id,
  'guid': 'sync-lab-placeholder-$id',
  'stability': 1.0,
  'difficulty': 5.0,
  'due': '2020-01-01T03:00:00.000Z',
  'state': 2,
  'reps': 1,
  'lapses': 0,
  'last_review': '2019-12-31T03:00:00.000Z',
  'cloud_seen': true,
  'notes': {
    'front': 'synthetic placeholder',
    'back': 'synthetic placeholder',
    'has_latex': false,
    'deck_id': 1,
    'latex_svg': null,
    'tags': '',
  },
};

void main() {
  test('real fetchQueue rejects a nonadvancing due cursor', () async {
    var dueRequests = 0;
    final client = SupabaseClient(
      'https://sync-lab.invalid',
      'synthetic-not-a-credential',
      httpClient: MockClient((request) async {
        final isDue =
            request.url.path.endsWith('/cards') &&
            request.url.queryParameters['state'] == 'neq.0';
        if (isDue) {
          dueRequests++;
          // Bound a faulty implementation without a test timeout or live IO.
          expect(dueRequests, lessThanOrEqualTo(2));
        }
        return http.Response(
          jsonEncode(isDue ? [_syntheticDueRow(1)] : []),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    await expectLater(
      RecallApi(client).fetchQueue(newLimit: 0),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Due-card pagination did not advance'),
        ),
      ),
    );
    expect(dueRequests, 2);
  });
  for (final serverCap in [1, 500, 137]) {
    for (final count in serverCap == 1 ? [2] : [499, 500, 501, 1001]) {
      test('real fetchQueue count=$count transportCap=$serverCap', () async {
        // Odd IDs and equal due timestamps require the actual id tie-breaker.
        final rows = [
          for (var i = 0; i < count; i++) _syntheticDueRow(2 * i + 1),
        ];
        final dueRequests = <Map<String, Object?>>[];
        final client = SupabaseClient(
          'https://sync-lab.invalid',
          'synthetic-not-a-credential',
          httpClient: MockClient((request) async {
            final query = request.url.queryParameters;
            var page = <Map<String, dynamic>>[];
            if (request.url.path.endsWith('/cards') &&
                query['state'] == 'neq.0') {
              expect(request.method, 'GET');
              expect(query['order'], 'due.asc.nullslast,id.asc.nullslast');
              expect(query['deleted'], 'eq.false');
              expect(query['suspended'], 'eq.false');
              expect(query['limit'], '500');
              final cursor = query['or'];
              final match = cursor == null
                  ? null
                  : RegExp(r'id\.gt\.(\d+)').firstMatch(cursor);
              if (cursor != null) expect(match, isNotNull, reason: cursor);
              final afterId = match == null ? -1 : int.parse(match.group(1)!);
              page = rows
                  .where((row) => (row['id'] as int) > afterId)
                  .take(math.min(serverCap, int.parse(query['limit']!)))
                  .toList();
              dueRequests.add({
                'cursor': cursor,
                'afterId': afterId,
                'returned': page.length,
              });
              // A broken cursor must fail quickly instead of looping forever.
              expect(dueRequests.length, lessThanOrEqualTo(count + 2));
            }
            return http.Response(
              jsonEncode(page),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(client.dispose);
        final queue = await RecallApi(client).fetchQueue(newLimit: 0);
        expect(
          queue.map((card) => card.id).toList(),
          [for (final row in rows) row['id']],
          reason: jsonEncode({
            'synthetic': true,
            'count': count,
            'transportCap': serverCap,
            'actualCount': queue.length,
            'requests': dueRequests,
            'deployedServerCap': 'unverified',
          }),
        );
      });
    }
  }
}

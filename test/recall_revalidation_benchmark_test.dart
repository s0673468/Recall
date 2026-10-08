// Development transport model. Synthetic only; never a hosted latency claim.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

Map<String, dynamic> row(int id, {bool revised = true}) => {
  'id': id,
  'guid': 'development-$id',
  'stability': 31.25,
  'difficulty': 4.5,
  'due': '2027-01-01T00:00:00Z',
  'state': 2,
  'reps': 21,
  'lapses': 3,
  'last_review': '2026-08-01T00:00:00Z',
  'cloud_seen': true,
  'notes': {
    'front': 'Invented development prompt ${'x' * (id % 40)}',
    'back': 'Invented explanation ${'y' * (100 + id % 60)}',
    'has_latex': false,
    'deck_id': 1,
    'latex_svg': null,
    'tags': revised ? 'development content_revalidate::20260812T000000Z' : '',
  },
};

void main() {
  test('development whole-queue transport model preserves full result', () async {
    final delay = int.parse(
      Platform.environment['RECALL_MODEL_DELAY_MS'] ?? '0',
    );
    final repetitions = int.parse(
      Platform.environment['RECALL_MODEL_REPEATS'] ?? '1',
    );
    expect(delay, inInclusiveRange(0, 100));
    expect(repetitions, inInclusiveRange(1, 30));
    final samples = <Map<String, Object?>>[];
    String? reference;
    for (var run = 0; run < repetitions; run++) {
      var requestCount = 0,
          responseBytes = 0,
          candidateRequests = 0,
          acknowledgementRequests = 0,
          maxResponseBytes = 0,
          maxUrlBytes = 0,
          candidateRowsReturned = 0;
      final trace = <Map<String, Object?>>[];
      final elapsed = Stopwatch()..start();
      final client = SupabaseClient(
        'https://benchmark.invalid',
        'synthetic-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          requestCount++;
          final uri = request.url, q = uri.queryParameters;
          maxUrlBytes = maxUrlBytes > uri.toString().length
              ? maxUrlBytes
              : uri.toString().length;
          final started = elapsed.elapsedMicroseconds;
          if (delay > 0) {
            await Future<void>.delayed(Duration(milliseconds: delay));
          }
          List<Map<String, dynamic>> result;
          String lane;
          if (uri.path.endsWith('/cards') && q.containsKey('notes.tags')) {
            lane = 'candidate';
            candidateRequests++;
            final offset = int.parse(q['offset'] ?? '0');
            final size = int.parse(q['limit'] ?? '50');
            result = [
              for (var i = offset; i < offset + size && i < 450; i++)
                row(700000 + i),
            ];
            candidateRowsReturned += result.length;
          } else if (uri.path.endsWith('/review_log') &&
              q['select']?.startsWith('card_id,rating,rating_at') == true) {
            lane = 'acknowledgement';
            acknowledgementRequests++;
            final wanted = RegExp(r'\d+')
                .allMatches(q['card_id'] ?? '')
                .map((x) => int.parse(x[0]!))
                .toSet();
            final matching = [
              for (var i = 0; i < 420; i++)
                if (wanted.contains(700000 + i))
                  {
                    'id': 900000 + i,
                    'card_id': 700000 + i,
                    'rating': 3,
                    'rating_at': '2026-08-13T00:00:00Z',
                  },
            ];
            final offset = int.parse(q['offset'] ?? '0');
            final size = int.parse(q['limit'] ?? '1000');
            result = matching.skip(offset).take(size).toList();
          } else if (uri.path.endsWith('/cards') && q['state'] == 'neq.0') {
            lane = 'ordinary_due';
            // One overlaps the material lane; retain the ordinary other card.
            result = [row(700421), row(799999, revised: false)];
            // Both fixtures share a due time. Honor the real keyset's ID
            // tie-breaker instead of replaying the first page indefinitely.
            final cursor = q['or'];
            if (cursor != null) {
              final match = RegExp(r'id\.gt\.(\d+)').firstMatch(cursor);
              expect(match, isNotNull, reason: cursor);
              final afterId = int.parse(match!.group(1)!);
              final due = DateTime.parse(
                result.first['due'] as String,
              ).toUtc().toIso8601String();
              expect(cursor, '(due.gt.$due,and(due.eq.$due,id.gt.$afterId))');
              result = result.where((r) => (r['id'] as int) > afterId).toList();
            }
            result = result.take(int.parse(q['limit']!)).toList();
          } else {
            lane = 'ordinary_other';
            result = [];
          }
          final body = jsonEncode(result), bytes = utf8.encode(body).length;
          responseBytes += bytes;
          maxResponseBytes = maxResponseBytes > bytes
              ? maxResponseBytes
              : bytes;
          trace.add({
            'lane': lane,
            'start_us': started,
            'finish_us': elapsed.elapsedMicroseconds,
            'rows': result.length,
            'bytes': bytes,
          });
          return http.Response(
            body,
            200,
            request: request,
            headers: {
              'content-type': 'application/json',
              'content-range': '0-0/0',
            },
          );
        }),
      );
      try {
        final queue = await RecallApi(client).fetchQueue(includedDeckIds: {1});
        elapsed.stop();
        expect(
          trace
              .where((request) => request['lane'] == 'ordinary_due')
              .map((request) => request['rows']),
          [2, 0],
          reason: 'A short due page still needs an empty exhaustion page.',
        );
        expect(queue.map((x) => x.id).toList(), [
          for (var i = 420; i < 440; i++) 700000 + i,
          799999,
        ]);
        expect(
          queue.take(20).every((x) => x.contentRevalidationPending),
          isTrue,
        );
        expect(
          queue.every(
            (x) =>
                x.stability == 31.25 &&
                x.difficulty == 4.5 &&
                x.reps == 21 &&
                x.lapses == 3,
          ),
          isTrue,
        );
        final semantic = jsonEncode([
          for (final c in queue)
            {
              'id': c.id,
              'guid': c.guid,
              'front': c.front,
              'back': c.back,
              'stability': c.stability,
              'difficulty': c.difficulty,
              'reps': c.reps,
              'lapses': c.lapses,
              'due': c.due?.toIso8601String(),
              'pending': c.contentRevalidationPending,
            },
        ]);
        reference ??= semantic;
        expect(semantic, reference);
        samples.add({
          'run': run,
          'classification': run == 0
              ? 'first_model_observation'
              : 'independent_client_no_cache',
          'elapsed_us': elapsed.elapsedMicroseconds,
          'requests': requestCount,
          'candidate_requests': candidateRequests,
          'acknowledgement_requests': acknowledgementRequests,
          'candidate_rows_returned': candidateRowsReturned,
          'response_bytes': responseBytes,
          'max_response_bytes': maxResponseBytes,
          'max_url_bytes': maxUrlBytes,
          'queue_rows': queue.length,
          'trace': trace,
        });
      } finally {
        await client.dispose();
      }
    }
    stdout.writeln(
      'RECALL_DEVELOPMENT_METRICS=${jsonEncode({
        'schema': 'recall.revalidation.transport-model/v1',
        'fixed_delay_ms_per_request': delay,
        'samples': samples,
        'semantic': reference,
        'peak_client_process_rss_bytes': ProcessInfo.maxRss,
        'limits': ['invented development data, not private/cloud payload', 'fixed transport-delay model, not real network or user startup latency', 'first observation retained; no cache prefill or warmup', 'process RSS includes Flutter test runner, not hosted database memory'],
      })}',
    );
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

import 'support/recall_test_harness.dart';

class _DownloadedHidesApi extends FakeRecallApi {
  final RecallApi remote;

  _DownloadedHidesApi(this.remote)
    : super([testCard(id: 90), testCard(id: 4), testCard(id: 80)]);

  @override
  Future<Set<int>> fetchHiddenCardIds() => remote.fetchHiddenCardIds();
}

// Synthetic rows and an intercepted .invalid endpoint; no auth/session data.
SupabaseClient _client(Future<http.Response> Function(http.Request) respond) {
  final client = SupabaseClient(
    'https://recall-fixture.invalid',
    'public-test-placeholder',
    httpClient: MockClient(respond),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return client;
}

http.Response _json(http.Request request, Object body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      request: request,
      headers: {'content-type': 'application/json'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('remote hides page by flag ID through a smaller server cap', () async {
    // Nonconsecutive IDs and multiple open flags for the same card are normal.
    // Card IDs are neither unique per flag nor ordered like the flag IDs.
    final rows = [
      {'id': 3, 'card_id': 90},
      {'id': 7, 'card_id': 90},
      {'id': 12, 'card_id': 4},
      {'id': 25, 'card_id': 80},
      {'id': 30, 'card_id': 2},
    ];
    final requests = <Uri>[];
    final api = RecallApi(
      _client((request) async {
        requests.add(request.url);
        final cursor = request.url.queryParameters['id'];
        final after = cursor == null ? 0 : int.parse(cursor.substring(3));
        final page = rows.where((row) => row['id']! > after).take(2).toList();
        return _json(request, page);
      }),
    );

    expect(await api.fetchHiddenCardIds(), {90, 4, 80, 2});
    expect(requests.map((uri) => uri.queryParameters['id']), [
      null,
      'gt.7',
      'gt.25',
      'gt.30',
    ]);
    for (final uri in requests) {
      expect(uri.path, '/rest/v1/note_flags');
      expect(uri.queryParameters['select'], 'id,card_id');
      expect(uri.queryParameters['status'], 'eq.open');
      expect(uri.queryParameters['reason'], 'in.("dislike","delete")');
      expect(uri.queryParameters['order'], startsWith('id.asc'));
    }
  });

  test(
    'a later hidden-state page failure cannot return a partial set',
    () async {
      var reads = 0;
      final api = RecallApi(
        _client((request) async {
          reads++;
          if (reads == 1) {
            return _json(request, [
              {'id': 3, 'card_id': 90},
            ]);
          }
          return _json(request, {
            'code': '42501',
            'message': 'synthetic read failure',
          }, status: 403);
        }),
      );

      await expectLater(
        api.fetchHiddenCardIds(),
        throwsA(isA<PostgrestException>()),
      );
      expect(reads, 2);
    },
  );

  test('a repeated hidden-state page defers instead of looping', () async {
    var reads = 0;
    final api = RecallApi(
      _client((request) async {
        reads++;
        if (reads > 3) throw StateError('synthetic excessive reads');
        return _json(request, [
          {'id': 3, 'card_id': 90},
        ]);
      }),
    );

    await expectLater(api.fetchHiddenCardIds(), throwsStateError);
    expect(reads, 2);
  });

  for (final failLaterPage in [false, true]) {
    test(
      failLaterPage
          ? 'failed later page keeps cached hides out of the study queue'
          : 'hides from another device beyond the cap stay out of the queue',
      () async {
        final remote = RecallApi(
          _client((request) async {
            final cursor = request.url.queryParameters['id'];
            if (cursor == null) {
              return _json(request, [
                {'id': 3, 'card_id': 90},
              ]);
            }
            if (failLaterPage) {
              return _json(request, {
                'code': '42501',
                'message': 'synthetic later-page failure',
              }, status: 403);
            }
            return _json(request, [
              if (cursor == 'gt.3') {'id': 12, 'card_id': 4},
            ]);
          }),
        );
        final store = LocalReviewStore();
        if (failLaterPage) await store.replaceHiddenCards({90, 4});
        final api = _DownloadedHidesApi(remote);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(controller.state.queue.map((card) => card.id), [80]);
        expect(api.lastExcludedCardIds, {90, 4});
        expect(await store.hiddenCardIds(), {90, 4});
      },
    );
  }
}

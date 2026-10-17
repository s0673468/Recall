import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

Map<String, dynamic> _cardRow(int id, {required int state}) => {
  'id': id,
  'guid': 'g$id',
  'stability': 10.0,
  'difficulty': 5.0,
  'due': DateTime.utc(2026, 8, 5, 11).toIso8601String(),
  'state': state,
  'reps': state == 0 ? 0 : 5,
  'lapses': 0,
  'last_review': state == 0
      ? null
      : DateTime.utc(2026, 8, 1).toIso8601String(),
  'cloud_seen': false,
  'notes': {
    'front': 'front$id',
    'back': 'back$id',
    'has_latex': false,
    'deck_id': 1,
    'latex_svg': null,
  },
};

bool _isDue(http.Request r) =>
    r.url.path.endsWith('/cards') && r.url.query.contains('state=neq.0');
bool _isNew(http.Request r) =>
    r.url.path.endsWith('/cards') && r.url.queryParameters['state'] == 'eq.0';
bool _isTodayLog(http.Request r) =>
    r.url.path.endsWith('/review_log') && !r.url.query.contains('card_id=in.');
bool _isPriorLog(http.Request r) =>
    r.url.path.endsWith('/review_log') && r.url.query.contains('card_id=in.');
bool _isFirstPage(http.Request r) =>
    !r.url.queryParameters.containsKey('id') &&
    !r.url.queryParameters.containsKey('or');

/// A fake PostgREST backend whose requests all wait for the test to release
/// them. Releasing every in-flight request at once models one network round
/// trip, so [rounds] is the number of serial round trips on the critical path.
class _RoundNetwork {
  _RoundNetwork(this.respond);

  final List<Map<String, dynamic>> Function(http.Request request) respond;
  final requests = <http.Request>[];
  final _inFlight = <({http.Request request, Completer<http.Response> done})>[];

  late final client = SupabaseClient(
    'https://example.supabase.co',
    'anon-key',
    httpClient: MockClient((request) {
      requests.add(request);
      final done = Completer<http.Response>();
      _inFlight.add((request: request, done: done));
      return done.future;
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  List<http.Request> get inFlight => [for (final e in _inFlight) e.request];

  /// Let request building and response decoding run to quiescence. Large
  /// bodies decode on a background isolate, so wait in real time until the
  /// set of issued requests has stopped changing.
  Future<void> settle({bool Function()? finished}) async {
    var stable = 0;
    var seen = requests.length;
    while (stable < 10) {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (finished?.call() ?? false) return;
      if (requests.length == seen) {
        stable++;
      } else {
        seen = requests.length;
        stable = 0;
      }
    }
  }

  void _releaseAll() {
    final batch = List.of(_inFlight);
    _inFlight.clear();
    for (final entry in batch) {
      entry.done.complete(
        http.Response(
          jsonEncode(respond(entry.request)),
          200,
          request: entry.request,
          headers: {'content-type': 'application/json'},
        ),
      );
    }
  }

  /// Drive [operation] round by round and report how many rounds it needed.
  Future<({T result, int rounds})> run<T>(Future<T> Function() operation) async {
    T? result;
    Object? error;
    var finished = false;
    unawaited(
      operation().then(
        (value) {
          result = value;
          finished = true;
        },
        onError: (Object e) {
          error = e;
          finished = true;
        },
      ),
    );
    var rounds = 0;
    await settle(finished: () => finished);
    while (!finished) {
      if (_inFlight.isEmpty) fail('operation stalled without a request');
      if (++rounds > 50) fail('operation did not converge');
      _releaseAll();
      await settle(finished: () => finished);
    }
    if (error != null) throw error!;
    return (result: result as T, rounds: rounds);
  }
}

void main() {
  test(
    'fetchQueue requests due cards before introduction history resolves',
    () async {
      final network = _RoundNetwork((_) => const []);
      addTearDown(network.client.dispose);

      unawaited(RecallApi(network.client).fetchQueue(newLimit: 20));
      await network.settle();

      // First wave: today's introduction history and the first due page are
      // both on the wire. The new-card page waits for the introduction count.
      final first = network.inFlight;
      expect(first.where(_isTodayLog), hasLength(1));
      expect(first.where(_isDue), hasLength(1));
      expect(first.where(_isNew), isEmpty);
    },
  );

  test('a day with reviews costs the longer chain, not the sum', () async {
    // Today: cards 1 and 2 were reviewed, card 2 for the first time ever.
    // Prior history proves card 1 was seen before. Two due cards, one page.
    final network = _RoundNetwork((r) {
      if (_isTodayLog(r)) {
        return _isFirstPage(r)
            ? [
                {'id': 10, 'card_id': 1},
                {'id': 11, 'card_id': 2},
              ]
            : [];
      }
      if (_isPriorLog(r)) {
        return _isFirstPage(r)
            ? [
                {'id': 3, 'card_id': 1},
              ]
            : [];
      }
      if (_isDue(r)) {
        return _isFirstPage(r)
            ? [_cardRow(1, state: 2), _cardRow(3, state: 2)]
            : [];
      }
      if (_isNew(r)) return [_cardRow(50, state: 0)];
      return [];
    });
    addTearDown(network.client.dispose);

    final run = await network.run(
      () => RecallApi(network.client).fetchQueue(newLimit: 20),
    );

    // Introductions: today page, today terminator, prior page, prior
    // terminator, then the new page = 5 serial round trips. Due paging (2) and
    // the revalidation lane (1) now overlap them. Before, due paging started
    // only after history (4) and overlapped just the new page: 4 + 2 = 6.
    expect(run.rounds, 5);
    expect([for (final c in run.result) c.id], [1, 3, 50]);
    final newRequest = network.requests.singleWhere(_isNew);
    expect(newRequest.url.queryParameters['limit'], '19');
  });

  test('a fresh day with a small queue needs two round trips', () async {
    // No reviews yet today; one due page plus its empty terminator.
    final network = _RoundNetwork((r) {
      if (_isDue(r)) return _isFirstPage(r) ? [_cardRow(1, state: 2)] : [];
      if (_isNew(r)) return [_cardRow(50, state: 0)];
      return [];
    });
    addTearDown(network.client.dispose);

    final run = await network.run(
      () => RecallApi(network.client).fetchQueue(newLimit: 20),
    );

    // Before: history (1), then due page + new page (1), then the due
    // terminator (1) = 3. Now history overlaps the first due page.
    expect(run.rounds, 2);
    expect([for (final c in run.result) c.id], [1, 50]);
  });

  test('a large due backlog no longer waits behind history', () async {
    // 3 full due pages plus the empty terminator page, no reviews today.
    final network = _RoundNetwork((r) {
      if (_isDue(r)) {
        final cursor = r.url.queryParameters['or'];
        final page = cursor == null
            ? 0
            : cursor.contains('id.gt.499')
            ? 1
            : cursor.contains('id.gt.999')
            ? 2
            : 3;
        if (page == 3) return [];
        return [
          for (var i = page * 500; i < (page + 1) * 500; i++)
            _cardRow(i, state: 2),
        ];
      }
      return [];
    });
    addTearDown(network.client.dispose);

    final run = await network.run(
      () => RecallApi(network.client).fetchQueue(newLimit: 20),
    );

    // Due paging alone is 4 round trips; history (1) then new (1) fit inside
    // it. Serially this was 1 + 4 = 5.
    expect(run.rounds, 4);
    expect(run.result, hasLength(1500));
    final newRequest = network.requests.singleWhere(_isNew);
    expect(newRequest.url.queryParameters['limit'], '20');
  });

  test('an introduction-history failure still fails the queue read', () async {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/review_log')) {
          return http.Response(
            jsonEncode({'message': 'history unavailable'}),
            503,
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

    // The budget cannot be computed, so the read fails rather than serving
    // an over-limit new-card page; the concurrent due read leaks no error.
    await expectLater(
      RecallApi(client).fetchQueue(newLimit: 20),
      throwsA(isA<PostgrestException>()),
    );
  });
}

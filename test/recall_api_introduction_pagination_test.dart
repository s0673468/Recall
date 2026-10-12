import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  test(
    'daily introductions drain short capped pages by unique log ID',
    () async {
      final fixture = _HistoryFixture(
        cap: 2,
        today: [(7, 41), (19, 41), (32, 42), (47, 43), (93, 44)],
      );
      final client = fixture.client();
      addTearDown(client.dispose);

      await RecallApi(client).fetchQueue(newLimit: 20);

      expect(fixture.newLimit, 16);
      expect(fixture.todayRequests.map((uri) => uri.queryParameters['id']), [
        null,
        'gt.19',
        'gt.47',
        'gt.93',
      ]);
      expect(
        fixture.todayRequests.map((uri) => uri.queryParameters['order']),
        everyElement('id.asc.nullslast'),
      );
      expect(
        fixture.historyRequests,
        everyElement(
          predicate<Uri>(
            (uri) => uri.queryParameters['select']!.startsWith('id,card_id'),
          ),
        ),
      );
    },
  );

  test(
    'repeat-heavy prior pages cannot hide an earlier introduction',
    () async {
      final fixture = _HistoryFixture(
        cap: 3,
        today: [(100, 41), (110, 42), (120, 43)],
        prior: [(10, 41), (20, 41), (30, 41), (40, 42)],
      );
      final client = fixture.client();
      addTearDown(client.dispose);

      await RecallApi(client).fetchQueue(newLimit: 20);

      expect(fixture.newLimit, 19);
      expect(fixture.priorRequests.map((uri) => uri.queryParameters['id']), [
        null,
        'gt.30',
        'gt.40',
      ]);
    },
  );

  test('an exhausted daily budget cannot admit another new card', () async {
    final fixture = _HistoryFixture(cap: 1, today: [(1, 41), (2, 42), (3, 43)]);
    final client = fixture.client();
    addTearDown(client.dispose);

    await RecallApi(client).fetchQueue(newLimit: 2);

    expect(fixture.newLimit, 0);
  });

  for (final explicitDeck in [true, false]) {
    test(
      'every history page preserves ${explicitDeck ? 'explicit' : 'included'} deck scope',
      () async {
        final fixture = _HistoryFixture(
          cap: 1,
          today: [(10, 41), (20, 42), (30, 43), (40, 44)],
          prior: [(1, 41)],
          decks: {41: 7, 42: 9, 43: 4, 44: 7},
        );
        final client = fixture.client();
        addTearDown(client.dispose);

        await RecallApi(client).fetchQueue(
          deckId: explicitDeck ? 7 : null,
          includedDeckIds: explicitDeck ? {4} : {9, 7},
          newLimit: 10,
        );

        expect(fixture.newLimit, explicitDeck ? 9 : 8);
        expect(fixture.historyRequests, isNotEmpty);
        for (final uri in fixture.historyRequests) {
          expect(
            uri.queryParameters['cards.notes.deck_id'],
            explicitDeck ? 'eq.7' : 'in.(7,9)',
          );
          expect(
            uri.queryParameters['select'],
            'id,card_id,cards!inner(notes!inner(deck_id))',
          );
        }
      },
    );
  }

  test('empty included decks make no HTTP requests', () async {
    final fixture = _HistoryFixture(cap: 1, today: [(1, 41)]);
    final client = fixture.client();
    addTearDown(client.dispose);

    expect(
      await RecallApi(client).fetchQueue(includedDeckIds: const {}),
      isEmpty,
    );
    expect(fixture.requests, isEmpty);
  });

  test('paging preserves the existing half-open local-day boundary', () async {
    final fixture = _HistoryFixture(cap: 1, today: [(10, 41), (20, 42)]);
    // These rows prove start is inclusive and end is exclusive. The earlier
    // review prevents card 41 from being counted as a first introduction.
    fixture.rows
      ..clear()
      ..addAll([
        fixture.row(
          1,
          41,
          fixture.start.subtract(const Duration(microseconds: 1)),
        ),
        fixture.row(10, 41, fixture.start),
        fixture.row(
          20,
          42,
          fixture.end.subtract(const Duration(microseconds: 1)),
        ),
        fixture.row(30, 43, fixture.end),
      ]);
    final client = fixture.client();
    addTearDown(client.dispose);

    await RecallApi(client).fetchQueue(newLimit: 10);

    expect(fixture.newLimit, 9);
    for (final uri in fixture.todayRequests) {
      expect(uri.queryParametersAll['rating_at'], [
        'gte.${fixture.start.toUtc().toIso8601String()}',
        'lt.${fixture.end.toUtc().toIso8601String()}',
      ]);
    }
    for (final uri in fixture.priorRequests) {
      expect(uri.queryParametersAll['rating_at'], [
        'lt.${fixture.start.toUtc().toIso8601String()}',
      ]);
    }
  });

  test(
    'large daily ID sets use bounded independent prior-history batches',
    () async {
      final fixture = _HistoryFixture(
        cap: 31,
        today: [for (var i = 1; i <= 205; i++) (1000 + i, i)],
        prior: [for (var i = 1; i <= 205; i += 2) (i, i)],
      );
      final client = fixture.client();
      addTearDown(client.dispose);

      await RecallApi(client).fetchQueue(newLimit: 250);

      expect(fixture.newLimit, 148);
      final batches = {
        for (final uri in fixture.priorRequests)
          uri.queryParameters['card_id']!,
      };
      expect(batches, hasLength(3));
      final covered = <int>{};
      for (final filter in batches) {
        final ids = _inIds(filter);
        expect(ids.length, lessThanOrEqualTo(100));
        expect(covered.intersection(ids), isEmpty);
        covered.addAll(ids);
        final pages = fixture.priorRequests.where(
          (uri) => uri.queryParameters['card_id'] == filter,
        );
        expect(pages.first.queryParameters['id'], isNull);
      }
      expect(covered, {for (var i = 1; i <= 205; i++) i});
    },
  );

  for (final repeatPrior in [false, true]) {
    test(
      '${repeatPrior ? 'prior' : 'today'} history refuses a repeated page without advancing',
      () async {
        final fixture = _HistoryFixture(
          cap: 1,
          today: [(10, 41)],
          prior: repeatPrior ? [(1, 41)] : [],
          repeatToday: !repeatPrior,
          repeatPrior: repeatPrior,
        );
        final client = fixture.client();
        addTearDown(client.dispose);

        await expectLater(
          RecallApi(client).fetchQueue(newLimit: 20),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Introduction-history pagination did not advance'),
            ),
          ),
        );

        expect(
          repeatPrior ? fixture.priorRequests : fixture.todayRequests,
          hasLength(2),
        );
        expect(fixture.newLimit, isNull);
      },
    );
  }

  test(
    'history transport failure propagates without admitting new cards',
    () async {
      final fixture = _HistoryFixture(cap: 1, today: [(10, 41)], failAfter: 1);
      final client = fixture.client();
      addTearDown(client.dispose);

      await expectLater(
        RecallApi(client).fetchQueue(newLimit: 20),
        throwsA(isA<PostgrestException>()),
      );

      expect(fixture.todayRequests, hasLength(2));
      expect(fixture.newLimit, isNull);
    },
  );
}

class _HistoryFixture {
  final int cap;
  final bool repeatToday;
  final bool repeatPrior;
  final int? failAfter;
  final Map<int, int> decks;
  final List<Map<String, dynamic>> rows = [];
  final List<Uri> requests = [];
  late final DateTime start;
  late final DateTime end;

  _HistoryFixture({
    required this.cap,
    required List<(int, int)> today,
    List<(int, int)> prior = const [],
    this.decks = const {},
    this.repeatToday = false,
    this.repeatPrior = false,
    this.failAfter,
  }) {
    final now = DateTime.now();
    start = DateTime(now.year, now.month, now.day);
    end = start.add(const Duration(days: 1));
    rows.addAll([
      for (final (id, cardId) in prior)
        row(id, cardId, start.subtract(const Duration(seconds: 1))),
      for (final (id, cardId) in today)
        row(id, cardId, start.add(const Duration(hours: 1))),
    ]);
  }

  Map<String, dynamic> row(int id, int cardId, DateTime at) => {
    'id': id,
    'card_id': cardId,
    'rating_at': at.toUtc().toIso8601String(),
    'deck_id': decks[cardId] ?? 1,
  };

  List<Uri> get historyRequests =>
      requests.where((uri) => uri.path.endsWith('/review_log')).toList();
  List<Uri> get todayRequests => historyRequests
      .where((uri) => !uri.queryParameters.containsKey('card_id'))
      .toList();
  List<Uri> get priorRequests => historyRequests
      .where((uri) => uri.queryParameters.containsKey('card_id'))
      .toList();
  int? get newLimit {
    final matches = requests.where(
      (uri) =>
          uri.path.endsWith('/cards') && uri.queryParameters['state'] == 'eq.0',
    );
    return matches.isEmpty
        ? null
        : int.parse(matches.single.queryParameters['limit']!);
  }

  SupabaseClient client() => SupabaseClient(
    'https://recall-introduction-fixture.invalid',
    'invented-anon-key',
    httpClient: MockClient((request) async {
      requests.add(request.url);
      if (!request.url.path.endsWith('/review_log')) {
        return _response(request, const []);
      }
      if (failAfter != null && historyRequests.length > failAfter!) {
        return http.Response(
          '{"message":"invented unavailable history","code":"XX000"}',
          400,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      final query = request.url.queryParameters;
      final prior = query.containsKey('card_id');
      final repeat = prior ? repeatPrior : repeatToday;
      var matching = rows.where((row) {
        final at = DateTime.parse(row['rating_at'] as String);
        for (final filter
            in request.url.queryParametersAll['rating_at'] ?? []) {
          if (filter.startsWith('gte.') &&
              at.isBefore(DateTime.parse(filter.substring(4)))) {
            return false;
          }
          if (filter.startsWith('lt.') &&
              !at.isBefore(DateTime.parse(filter.substring(3)))) {
            return false;
          }
        }
        final cardFilter = query['card_id'];
        if (cardFilter != null &&
            !_inIds(cardFilter).contains(row['card_id'])) {
          return false;
        }
        final scope = query['cards.notes.deck_id'];
        if (scope != null) {
          if (scope.startsWith('eq.') &&
              row['deck_id'] != int.parse(scope.substring(3))) {
            return false;
          }
          if (scope.startsWith('in.') &&
              !_inIds(scope).contains(row['deck_id'])) {
            return false;
          }
        }
        final cursor = query['id'];
        return repeat ||
            cursor == null ||
            (row['id'] as int) > int.parse(cursor.substring(3));
      }).toList()..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
      final requested = int.tryParse(query['limit'] ?? '') ?? rows.length;
      matching = matching.take(requested < cap ? requested : cap).toList();
      final selected = query['select']!.split(',');
      return _response(request, [
        for (final row in matching)
          {
            if (selected.contains('id')) 'id': row['id'],
            'card_id': row['card_id'],
          },
      ]);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

Set<int> _inIds(String filter) =>
    filter.substring(4, filter.length - 1).split(',').map(int.parse).toSet();

http.Response _response(
  http.Request request,
  List<Map<String, dynamic>> rows,
) => http.Response(
  jsonEncode(rows),
  200,
  request: request,
  headers: {'content-type': 'application/json'},
);

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  for (final cap in [2, 1000]) {
    test('all decks and counts survive a server row cap of $cap', () async {
      final fixture = _DeckTransport(cap: cap);
      final api = fixture.api();
      final decks = await api.fetchDecks();
      final counts = await api.fetchDeckCounts();

      expect(decks, hasLength(1003));
      expect(decks.map((d) => d.deckId).toSet(), hasLength(1003));
      expect(decks.first.name, 'Deck 1003');
      expect(decks.last.name, 'Deck 0001');
      expect(counts, hasLength(1003));
      expect(counts[1003], (due: 1003, neu: 0));
      expect(counts.values.fold<int>(0, (sum, c) => sum + c.due), 503506);
      for (final uri in fixture.requests) {
        expect(uri.queryParameters['order'], 'deck_id.asc.nullslast');
        if (uri.path.endsWith('/decks')) {
          expect(uri.queryParameters['deleted'], 'eq.false');
          expect(uri.queryParameters['select'], 'deck_id,name');
        }
      }
    });
  }

  test(
    'renaming and moving a deck between pages does not skip its ID',
    () async {
      final fixture = _DeckTransport(cap: 2, size: 4)
        ..names = {1: 'Z', 2: 'Same', 3: 'Same', 4: 'A'}
        ..renamedOnSecondPage = {4: 'Opt-in::Nested::A'};
      final decks = await fixture.api().fetchDecks();
      expect(decks.map((d) => d.deckId), [1, 2, 3, 4]);
      expect(decks.map((d) => d.name), [
        'Z',
        'Same',
        'Same',
        'Opt-in::Nested::A',
      ]);
    },
  );

  for (final counts in [false, true]) {
    test('${counts ? 'counts' : 'decks'} stop on an empty response', () async {
      final fixture = _DeckTransport(cap: 2, size: 0);
      final api = fixture.api();
      if (counts) {
        expect(await api.fetchDeckCounts(), isEmpty);
      } else {
        expect(await api.fetchDecks(), isEmpty);
      }
      expect(fixture.requests, hasLength(1));
    });

    test('${counts ? 'counts' : 'decks'} refuse a repeated page', () async {
      final fixture = _DeckTransport(cap: 2, size: 3)..repeatPage = true;
      final api = fixture.api();
      await expectLater(
        counts ? api.fetchDeckCounts() : api.fetchDecks(),
        throwsStateError,
      );
      expect(fixture.requests, hasLength(2));
    });

    test(
      '${counts ? 'counts' : 'decks'} do not return partial results on error',
      () async {
        final fixture = _DeckTransport(cap: 2, size: 3)..failSecondPage = true;
        final api = fixture.api();
        await expectLater(
          counts ? api.fetchDeckCounts() : api.fetchDecks(),
          throwsA(isA<PostgrestException>()),
        );
      },
    );
  }
}

/// Only synthetic deck IDs, names and numeric counts. No card reads or network.
class _DeckTransport {
  _DeckTransport({required this.cap, this.size = 1003});

  final int cap;
  final int size;
  final requests = <Uri>[];
  Map<int, String> names = {};
  Map<int, String> renamedOnSecondPage = {};
  bool repeatPage = false;
  bool failSecondPage = false;

  RecallApi api() {
    final client = SupabaseClient(
      'https://deck-fixture.invalid',
      '',
      httpClient: MockClient((request) async {
        requests.add(request.url);
        if (requests.length == 2) names.addAll(renamedOnSecondPage);
        final query = request.url.queryParameters;
        final counts = request.url.path.endsWith('/rpc/deck_counts');
        expect(request.method, counts ? 'POST' : 'GET');
        expect(counts || request.url.path.endsWith('/decks'), isTrue);
        final cursor = query['deck_id'];
        if (cursor != null && failSecondPage) {
          return http.Response(
            '{"code":"22000","message":"synthetic failure"}',
            400,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        final after = repeatPage || cursor == null
            ? 0
            : int.parse(cursor.substring(3));
        final limit = int.tryParse(query['limit'] ?? '') ?? size;
        final ids = [
          for (var id = after + 1; id <= size; id++) id,
        ].take(limit < cap ? limit : cap);
        return http.Response(
          jsonEncode([
            for (final id in ids)
              if (counts)
                {'deck_id': id, 'due': id, 'new': 0}
              else
                {
                  'deck_id': id,
                  'name': names[id] ?? 'Deck ${id.toString().padLeft(4, '0')}',
                },
          ]),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return RecallApi(client);
  }
}

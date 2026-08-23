import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

void main() {
  group('RecallApi automatic deck scope', () {
    late List<Uri> requests;
    late SupabaseClient client;
    late RecallApi api;

    setUp(() {
      requests = [];
      final mock = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode(const <Map<String, dynamic>>[]),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      });
      client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: mock,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      api = RecallApi(client);
      addTearDown(client.dispose);
    });

    test('scopes every automatic queue lane to the included decks', () async {
      await api.fetchQueue(includedDeckIds: {1, 3}, newLimit: 5);

      final cardRequests = requests
          .where((uri) => uri.path.endsWith('/cards'))
          .toList();
      expect(cardRequests, hasLength(3));
      for (final uri in cardRequests) {
        expect(uri.queryParameters['notes.deck_id'], 'in.(1,3)');
      }

      final historyRequests = requests
          .where((uri) => uri.path.endsWith('/review_log'))
          .toList();
      expect(historyRequests, isNotEmpty);
      for (final uri in historyRequests) {
        expect(uri.queryParameters['cards.notes.deck_id'], 'in.(1,3)');
      }
    });

    test('an explicit deck remains directly reviewable', () async {
      await api.fetchQueue(deckId: 7, includedDeckIds: {1, 3}, newLimit: 5);

      final cardRequests = requests
          .where((uri) => uri.path.endsWith('/cards'))
          .toList();
      expect(cardRequests, hasLength(3));
      for (final uri in cardRequests) {
        expect(uri.queryParameters['notes.deck_id'], 'eq.7');
      }
    });

    test('an empty automatic stream performs no card query', () async {
      expect(
        await api.fetchQueue(includedDeckIds: const {}, newLimit: 5),
        isEmpty,
      );
      expect(requests, isEmpty);
    });

    test('scopes the keep-going queue to automatic decks', () async {
      await api.fetchAheadQueue(includedDeckIds: {1, 3});

      final cardRequests = requests
          .where((uri) => uri.path.endsWith('/cards'))
          .toList();
      expect(cardRequests, hasLength(2));
      for (final uri in cardRequests) {
        expect(uri.queryParameters['notes.deck_id'], 'in.(1,3)');
      }
    });

    test('scopes the due forecast to automatic decks', () async {
      await api.fetchDueDates(includedDeckIds: {1, 3});

      final request = requests.singleWhere(
        (uri) => uri.path.endsWith('/cards'),
      );
      expect(request.queryParameters['notes.deck_id'], 'in.(1,3)');
      expect(
        request.queryParameters['select'],
        contains('notes!inner(deck_id)'),
      );
    });

    test('an empty automatic stream performs no forecast query', () async {
      expect(await api.fetchDueDates(includedDeckIds: const {}), isEmpty);
      expect(requests, isEmpty);
    });

    test('an unrestricted due-date read remains available', () async {
      await api.fetchDueDates();

      final request = requests.singleWhere(
        (uri) => uri.path.endsWith('/cards'),
      );
      expect(request.queryParameters, isNot(contains('notes.deck_id')));
    });
  });
}

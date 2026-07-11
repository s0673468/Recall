import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

/// Suspended cards (`cards.suspended = true`, written one-way by the desktop
/// importer) are dormant: the app must never surface them in the study queue
/// or the due forecast, and it does so by filtering server-side so the payload
/// stays small. The card model is deliberately left unchanged — the client
/// never reads the column, it only asks the server to withhold those rows.
///
/// These tests drive the real [RecallApi] against a mock HTTP transport and
/// assert on the PostgREST query string, so they prove the literal
/// `suspended=eq.false` predicate reaches Supabase (a fake that re-implements
/// fetchQueue could not).
void main() {
  group('RecallApi suspended filtering', () {
    late List<Uri> requests;
    late SupabaseClient client;

    /// A Supabase client whose REST transport records every request URL and
    /// answers with [rows] as JSON. Auto-refresh is off so no auth timer or
    /// network call leaks out of the test.
    RecallApi apiReturning(List<Map<String, dynamic>> rows) {
      final mock = MockClient((req) async {
        requests.add(req.url);
        return http.Response(
          jsonEncode(rows),
          200,
          request: req,
          headers: {'content-type': 'application/json'},
        );
      });
      client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: mock,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(() => client.dispose());
      return RecallApi(client);
    }

    setUp(() => requests = []);

    /// Every request that hit the `cards` table.
    List<Uri> cardRequests() =>
        requests.where((u) => u.path.endsWith('/cards')).toList();

    test('fetchQueue filters suspended out of BOTH the due and new queries',
        () async {
      final api = apiReturning(const []);
      await api.fetchQueue(newLimit: 5);

      final cards = cardRequests();
      expect(cards, hasLength(2), reason: 'one due query + one new query');
      for (final u in cards) {
        expect(
          u.query,
          contains('suspended=eq.false'),
          reason: 'both queue queries must exclude suspended cards: $u',
        );
      }
      // Both halves of the queue are represented and each carries the filter.
      final due = cards.singleWhere((u) => u.query.contains('state=neq.0'));
      final neu = cards.singleWhere((u) => u.query.contains('state=eq.0'));
      expect(due.query, contains('suspended=eq.false'));
      expect(neu.query, contains('suspended=eq.false'));
    });

    test('fetchQueue keeps the suspended filter alongside a deck filter',
        () async {
      final api = apiReturning(const []);
      await api.fetchQueue(deckId: 7, newLimit: 5);

      final cards = cardRequests();
      expect(cards, hasLength(2));
      for (final u in cards) {
        // Deck restriction and suspension filter coexist on both queries.
        expect(u.query, contains('notes.deck_id=eq.7'));
        expect(u.query, contains('suspended=eq.false'));
      }
    });

    test('fetchDueDates excludes suspended cards from the forecast', () async {
      final api = apiReturning(const []);
      await api.fetchDueDates();

      final cards = cardRequests();
      expect(cards, hasLength(1));
      expect(cards.single.query, contains('suspended=eq.false'));
    });

    test('review history is NOT filtered by suspended (past reviews remain)',
        () async {
      // A suspended card keeps the stats/history of its earlier reviews; the
      // review_log read must therefore carry no suspended predicate.
      final api = apiReturning(const []);
      await api.fetchReviewLog();

      final logRequests =
          requests.where((u) => u.path.endsWith('/review_log')).toList();
      expect(logRequests, hasLength(1));
      expect(logRequests.single.query, isNot(contains('suspended')));
    });
  });
}

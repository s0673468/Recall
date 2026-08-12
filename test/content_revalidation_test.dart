import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/content_revalidation.dart';

Map<String, dynamic> _cardRow(int id, String tags) => {
  'id': id,
  'guid': 'g$id',
  'stability': 42.5,
  'difficulty': 3.25,
  'due': '2027-01-01T12:00:00Z',
  'state': 2,
  'reps': 17,
  'lapses': 2,
  'last_review': '2026-07-01T12:00:00Z',
  'cloud_seen': true,
  'notes': {
    'front': 'front $id',
    'back': 'back $id',
    'has_latex': false,
    'deck_id': 1,
    'latex_svg': null,
    'tags': tags,
  },
};

void main() {
  group('content revalidation marker', () {
    test('parses the newest strict UTC marker', () {
      expect(
        contentRevalidationRevision(
          'topic content_revalidate::20260811T120000Z '
          'content_revalidate::20260812T031500Z',
        ),
        DateTime.utc(2026, 8, 12, 3, 15),
      );
    });

    test('ignores wording tags and malformed or impossible markers', () {
      expect(contentRevalidationRevision('topic wording_only'), isNull);
      expect(
        contentRevalidationRevision('content_revalidate::2026-08-12'),
        isNull,
      );
      expect(
        contentRevalidationRevision('content_revalidate::20260230T120000Z'),
        isNull,
      );
    });

    test('only Hard, Good, and Easy count as successful', () {
      expect(isSuccessfulContentRevalidationRating(1), isFalse);
      expect(isSuccessfulContentRevalidationRating(2), isTrue);
      expect(isSuccessfulContentRevalidationRating(3), isTrue);
      expect(isSuccessfulContentRevalidationRating(4), isTrue);
    });
  });

  test(
    'material card stays pending through Again and clears after success',
    () async {
      final requests = <http.BaseRequest>[];
      var successfulRows = <Map<String, dynamic>>[];
      final rows = [
        _cardRow(41, 'topic content_revalidate::20260811T120000Z'),
        // Wording-only edits do not carry a marker and never enter the lane.
        _cardRow(42, 'topic wording_only'),
      ];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          final body = request.url.path.endsWith('/cards')
              ? jsonEncode(rows)
              : jsonEncode(successfulRows);
          return http.Response(
            body,
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final api = RecallApi(client);

      final first = await api.fetchContentRevalidationQueue();
      expect(first.map((card) => card.id), [41]);
      expect(first.single.contentRevalidationPending, isTrue);
      // Discovery copied every FSRS field exactly. It did not reset history or
      // make any write request.
      expect(first.single.stability, 42.5);
      expect(first.single.difficulty, 3.25);
      expect(first.single.reps, 17);
      expect(first.single.lapses, 2);
      expect(first.single.due, DateTime.utc(2027, 1, 1, 12));
      expect(requests.every((request) => request.method == 'GET'), isTrue);

      // Again is intentionally absent from the successful-rating query, so
      // the revision remains pending.
      successfulRows = [
        {'card_id': 41, 'rating': 1, 'rating_at': '2026-08-12T11:00:00Z'},
      ];
      final afterAgain = await api.fetchContentRevalidationQueue();
      expect(afterAgain.map((card) => card.id), [41]);

      successfulRows = [
        {'card_id': 41, 'rating': 2, 'rating_at': '2026-08-12T12:00:00Z'},
      ];
      final afterHard = await api.fetchContentRevalidationQueue();
      expect(afterHard, isEmpty);

      final reviewQueries = requests.where(
        (request) => request.url.path.endsWith('/review_log'),
      );
      expect(reviewQueries, isNotEmpty);
      expect(reviewQueries.last.url.query, contains('rating=gt.1'));
      expect(reviewQueries.last.url.query, contains('rating_at=gt.'));
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/rating_bar.dart';

ReviewCard _card({
  int id = 1,
  double? stability,
  double? difficulty,
  int state = 0,
  int reps = 0,
  int lapses = 0,
  DateTime? due,
  DateTime? lastReview,
  bool hasLatex = false,
  String front = 'front',
  String back = 'back',
}) => ReviewCard(
  id: id,
  guid: 'g$id',
  deckId: 1,
  front: front,
  back: back,
  hasLatex: hasLatex,
  stability: stability,
  difficulty: difficulty,
  due: due,
  state: state,
  reps: reps,
  lapses: lapses,
  lastReview: lastReview,
);

void main() {
  group('FsrsEngine', () {
    final engine = FsrsEngine();
    final now = DateTime.utc(2026, 6, 26, 12);

    test('a new card schedules forward and counts the rep', () {
      final out = engine.review(_card(state: 0), Rating.good, now: now);
      expect(out.reps, 1);
      expect(out.lapses, 0);
      expect(out.due.isAfter(now), isTrue);
      expect(out.state, isIn(const [1, 2])); // learning or review, never new
      expect(out.stability, greaterThan(0));
    });

    test('Again on a review card records a lapse', () {
      final out = engine.review(
        _card(
          id: 2,
          state: 2,
          stability: 10,
          difficulty: 5,
          reps: 3,
          due: DateTime.utc(2026, 6, 20),
          lastReview: DateTime.utc(2026, 6, 10),
        ),
        Rating.again,
        now: now,
      );
      expect(out.reps, 4);
      expect(out.lapses, 1);
    });

    test('preview gives four ratings with non-decreasing intervals', () {
      final p = engine.preview(_card(state: 0), now: now);
      expect(p.keys.toSet(), Rating.values.toSet());
      expect(!p[Rating.again]!.isAfter(p[Rating.good]!), isTrue);
      expect(!p[Rating.good]!.isAfter(p[Rating.easy]!), isTrue);
    });
  });

  group('UI widgets', () {
    testWidgets('RatingBar shows all four ratings and reports taps', (
      tester,
    ) async {
      Rating? tapped;
      final now = DateTime.now().toUtc();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RatingBar(
              preview: {
                for (final r in Rating.values)
                  r: now.add(Duration(days: r.value)),
              },
              onRate: (r) => tapped = r,
            ),
          ),
        ),
      );
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);

      await tester.tap(find.text('Easy'));
      expect(tapped, Rating.easy);
    });

    testWidgets('CardFace renders plain text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: 'What is backprop?',
              hasLatex: false,
              style: TextStyle(),
            ),
          ),
        ),
      );
      expect(find.textContaining('backprop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CardFace renders inline LaTeX without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: r'Embedding: vocab \(=5000\), dim \([32,10]\)',
              hasLatex: true,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Offline store', () {
    test('snapshot round-trips decks + queue', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [
          _card(
            id: 7,
            state: 2,
            stability: 5,
            difficulty: 3,
            due: DateTime.utc(2026, 7, 1),
            hasLatex: true,
            front: r'vocab \(=5000\)',
          ),
        ],
      );
      final snap = await store.loadSnapshot();
      expect(snap, isNotNull);
      expect(snap!.decks.single.name, 'ML');
      expect(snap.queue.single.id, 7);
      expect(snap.queue.single.hasLatex, isTrue);
      expect(snap.queue.single.stability, 5);
    });

    test('outbox enqueues and drains', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.enqueueReview({'card_id': 1, 'rating': 3});
      await store.enqueueReview({'card_id': 2, 'rating': 4});
      expect((await store.outbox()).length, 2);
      // Simulate one synced, one still pending.
      await store.replaceOutbox([
        {'card_id': 2, 'rating': 4},
      ]);
      final left = await store.outbox();
      expect(left.length, 1);
      expect(left.single['card_id'], 2);
    });

    test('clear() drops snapshot + outbox (sign-out)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [_card(id: 1)],
      );
      await store.enqueueReview({'card_id': 1, 'rating': 3});
      await store.clear();
      expect(await store.loadSnapshot(), isNull);
      expect(await store.outbox(), isEmpty);
    });
  });
}

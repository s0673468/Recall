import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/data/models.dart';

void main() {
  group('automatic review stream', () {
    test('keeps technical decks automatic, including ML-extra', () {
      expect(
        automaticReviewDeckIds(const [
          DeckRow(deckId: 1, name: 'ML'),
          DeckRow(deckId: 2, name: 'Math'),
          DeckRow(deckId: 3, name: 'ML-extra'),
        ]),
        {1, 2, 3},
      );
    });

    test('keeps opt-in curricula out of the automatic stream', () {
      expect(
        automaticReviewDeckIds(const [
          DeckRow(deckId: 1, name: 'ML'),
          DeckRow(deckId: 2, name: 'Portuguese'),
          DeckRow(deckId: 3, name: 'Portuguese::Verbs'),
          DeckRow(deckId: 4, name: 'Opt-in::Russian Revolution'),
          DeckRow(deckId: 5, name: 'Experimental::Newsreel Research'),
        ]),
        {1},
      );
    });

    test('matches only full deck roots, not words containing extra', () {
      expect(isAutomaticReviewDeckName('ML-extra'), isTrue);
      expect(isAutomaticReviewDeckName('Extra Trees'), isTrue);
      expect(isAutomaticReviewDeckName('Opt-in::Portuguese'), isFalse);
    });
  });
}

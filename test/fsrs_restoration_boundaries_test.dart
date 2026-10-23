// Synthetic scheduling rows only; no stored cards or fitted user parameters.
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating, defaultParameters;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

final _now = DateTime.utc(2026, 10, 23, 12);

ReviewCard _card({
  int state = 1,
  double? stability = 1,
  Duration gap = const Duration(minutes: 10),
}) => ReviewCard(
  id: 701,
  guid: 'synthetic-restoration',
  deckId: 1,
  front: '',
  back: '',
  hasLatex: false,
  stability: stability,
  difficulty: 5,
  due: _now,
  state: state,
  reps: 7,
  lapses: 2,
  lastReview: _now.subtract(gap),
);

void main() {
  group('durable learning step reconstruction', () {
    for (final scenario in [
      (
        label: 'just below',
        gap: const Duration(minutes: 10, microseconds: -1),
        graduates: false,
      ),
      (label: 'exactly at', gap: const Duration(minutes: 10), graduates: true),
      (
        label: 'just above',
        gap: const Duration(minutes: 10, microseconds: 1),
        graduates: true,
      ),
      (
        label: 'imported long gap',
        gap: const Duration(days: 30),
        graduates: true,
      ),
    ]) {
      test('Good ${scenario.label} the final step boundary', () {
        final engine = FsrsEngine();
        // Cross the JSON boundary: the persisted card has no transient step.
        final card = ReviewCard.fromJson(_card(gap: scenario.gap).toJson());
        final before = card.toJson();
        final preview = engine.preview(card, now: _now);
        final outcome = engine.review(card, Rating.good, now: _now);

        expect(outcome.state, scenario.graduates ? 2 : 1);
        if (scenario.graduates) {
          expect(
            outcome.due.difference(_now),
            greaterThanOrEqualTo(const Duration(days: 1)),
          );
        } else {
          expect(outcome.due, _now.add(const Duration(minutes: 10)));
        }
        expect(outcome.due, preview[Rating.good]);
        expect(outcome.reps, 8);
        expect(outcome.lapses, 2);
        expect(card.toJson(), before);
      });
    }

    for (final stability in <double?>[null, 0, -1]) {
      test('nonpositive or absent stability ($stability) starts fresh', () {
        final engine = FsrsEngine();
        final card = _card(state: 2, stability: stability);
        for (final rating in Rating.values) {
          final actual = engine.review(card, rating, now: _now);
          final fresh = engine.review(_card(state: 0), rating, now: _now);
          expect(actual.due, fresh.due);
          expect(actual.state, fresh.state);
          expect(actual.stability, fresh.stability);
          expect(actual.difficulty, fresh.difficulty);
          expect(actual.reps, 8);
          // The stored review state still determines lapse bookkeeping.
          expect(actual.lapses, rating == Rating.again ? 3 : 2);
        }
      });
    }
  });

  group('scheduler configuration ownership', () {
    test(
      'caller mutations cannot change fitted scheduling or clamp weight',
      () {
        final weights = [...defaultParameters]..[2] = 2;
        final expected = List<double>.of(weights);
        final engine = FsrsEngine();
        engine.configure(
          FsrsSettings(parameters: weights, desiredRetention: 0.85),
        );
        final card = _card(stability: 50);
        final before = engine.review(card, Rating.good, now: _now);

        weights[2] = 50;

        expect(engine.parameters, expected);
        expect(() => engine.parameters[2] = 50, throwsUnsupportedError);
        final after = engine.review(card, Rating.good, now: _now);
        expect(after.stability, before.stability);
        expect(after.due, before.due);
        expect(engine.preview(card, now: _now)[Rating.good], before.due);
      },
    );

    test(
      'a suggestion replaces a prior applied fit with package scheduling',
      () {
        final appliedWeights = [...defaultParameters]..[2] = 2;
        final engine = FsrsEngine();
        engine.configure(
          FsrsSettings(
            parameters: appliedWeights,
            desiredRetention: 0.8,
            fittedAt: DateTime.utc(2026, 10, 1),
          ),
        );
        final suggestedAt = DateTime.utc(2026, 10, 22);
        engine.configure(
          FsrsSettings(
            parameters: [...defaultParameters]..[2] = 40,
            desiredRetention: 0.7,
            optimizerStatus: FsrsConfigurationStatus.suggested,
            fittedAt: suggestedAt,
          ),
        );

        expect(engine.configurationStatus, FsrsConfigurationStatus.suggested);
        expect(engine.fittedAt, suggestedAt);
        expect(engine.parameters, defaultParameters);
        expect(engine.desiredRetention, 0.9);
        final defaults = FsrsEngine();
        for (final rating in Rating.values) {
          final actual = engine.review(_card(stability: 50), rating, now: _now);
          final expected = defaults.review(
            _card(stability: 50),
            rating,
            now: _now,
          );
          expect(actual.due, expected.due);
          expect(actual.stability, expected.stability);
        }

        engine.resetToDefaults();
        expect(
          engine.configurationStatus,
          FsrsConfigurationStatus.packageDefaults,
        );
        expect(engine.fittedAt, isNull);
      },
    );
  });
}

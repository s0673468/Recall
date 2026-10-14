import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating, defaultParameters;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FsrsEngine', () {
    final engine = FsrsEngine();
    final now = DateTime.utc(2026, 6, 26, 12);

    test('a new card schedules forward and counts the rep', () {
      final out = engine.review(testCard(state: 0), Rating.good, now: now);
      expect(out.reps, 1);
      expect(out.lapses, 0);
      expect(out.due.isAfter(now), isTrue);
      expect(out.state, isIn(const [1, 2])); // learning or review, never new
      expect(out.stability, greaterThan(0));
    });

    test('Again on a review card records a lapse', () {
      final out = engine.review(
        testCard(
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
      final p = engine.preview(testCard(state: 0), now: now);
      expect(p.keys.toSet(), Rating.values.toSet());
      expect(!p[Rating.again]!.isAfter(p[Rating.good]!), isTrue);
      expect(!p[Rating.good]!.isAfter(p[Rating.easy]!), isTrue);
    });

    test('preview is stable and matches the interval persisted on tap', () {
      // Regression for the reported mature-card profile: its UI showed
      // Hard 5d / Good 5d / Easy 16d, but tapping Good actually persisted 8d.
      // The package's random fuzz was drawn separately for each preview and
      // again for the tap.
      final configured = FsrsEngine(parameters: desktopFsrsParameters);
      final card = testCard(
        id: 42,
        state: 2,
        stability: 2.17292,
        difficulty: 5.08338,
        reps: 2,
        due: DateTime.utc(2026, 7, 30, 9, 50, 23, 757, 335),
        lastReview: DateTime.utc(2026, 7, 28, 9, 50, 23, 757, 335),
      );
      final reviewedAt = DateTime.utc(2026, 7, 30, 12, 22, 39, 421, 193);
      final expected = {
        Rating.again: const Duration(minutes: 10),
        Rating.hard: const Duration(days: 5),
        Rating.good: const Duration(days: 8),
        Rating.easy: const Duration(days: 15),
      };

      for (var attempt = 0; attempt < 10; attempt++) {
        final preview = configured.preview(card, now: reviewedAt);
        for (final rating in Rating.values) {
          expect(preview[rating]!.difference(reviewedAt), expected[rating]);
          expect(
            configured.review(card, rating, now: reviewedAt).due,
            preview[rating],
          );
        }
      }
    });

    test('preview restores a persisted relearning card without its step', () {
      final p = engine.preview(
        testCard(
          id: 3,
          state: 3,
          stability: 3,
          difficulty: 6,
          reps: 3,
          lapses: 1,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        now: now,
      );

      expect(p.keys.toSet(), Rating.values.toSet());
    });

    test('Good graduates a learning card whose last gap was the final step', () {
      // Persisted rows carry no `step`. This card's last scheduled gap was the
      // 10-minute (final) learning step, so Good must graduate it to days —
      // restoring it at step 0 would loop it at 10 minutes forever.
      final out = engine.review(
        testCard(
          id: 4,
          state: 1,
          stability: 1.5,
          difficulty: 5,
          reps: 1,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 2);
      expect(
        out.due.difference(now),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
    });

    test('Good moves a step-0 learning card to the next step, not out', () {
      // Last gap ≈ the 1-minute step (an Again press) — still step 0, so Good
      // advances to the 10-minute step rather than graduating.
      final out = engine.review(
        testCard(
          id: 5,
          state: 1,
          stability: 1.0,
          difficulty: 5,
          reps: 2,
          due: now.subtract(const Duration(seconds: 30)),
          lastReview: now.subtract(const Duration(seconds: 90)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 1);
      expect(out.due.difference(now), lessThan(const Duration(minutes: 15)));
    });

    test('loop-inflated learning stability is clamped on graduation', () {
      // Cards stuck in the pre-#12 learning loop had their stability
      // compounded to weeks or months. A card still in learning can't have
      // legitimately earned more than a first Good press (~w[2] days), so
      // Good must graduate it to days — not the months its row claims.
      final out = engine.review(
        testCard(
          id: 7,
          state: 1,
          stability: 117.4,
          difficulty: 5,
          reps: 9,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 2);
      expect(
        out.due.difference(now),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
      expect(out.due.difference(now), lessThan(const Duration(days: 10)));
    });

    test('relearning cards keep their real stability (no clamp)', () {
      // A lapsed mature card legitimately carries large stability through
      // relearning — graduating it back out must respect that.
      final out = engine.review(
        testCard(
          id: 8,
          state: 3,
          stability: 60,
          difficulty: 5,
          reps: 12,
          lapses: 2,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 2);
      expect(out.due.difference(now), greaterThan(const Duration(days: 30)));
    });

    test('rating previews show no cliff between Good and Easy', () {
      // The bug this pins down: Good previewing ~10 minutes while Easy
      // previews months, with nothing in between.
      final p = engine.preview(
        testCard(
          id: 6,
          state: 1,
          stability: 1.5,
          difficulty: 5,
          reps: 1,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        now: now,
      );
      expect(
        p[Rating.good]!.difference(now),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
      expect(!p[Rating.good]!.isAfter(p[Rating.easy]!), isTrue);
    });

    test('can be configured from seeded FSRS settings', () {
      final engine = FsrsEngine();
      engine.configure(
        const FsrsSettings(
          parameters: desktopFsrsParameters,
          desiredRetention: 0.82,
        ),
      );
      expect(engine.parameters, desktopFsrsParameters);
      expect(engine.desiredRetention, 0.82);
    });

    test('can reset back to package defaults', () {
      final engine = FsrsEngine(
        parameters: desktopFsrsParameters,
        desiredRetention: 0.82,
      );
      engine.resetToDefaults();
      expect(engine.parameters, defaultParameters);
      expect(engine.desiredRetention, 0.9);
    });
  });

  group('FsrsSettings', () {
    test('parses seeded parameters and desired retention', () {
      final parsed = FsrsSettings.tryParse({
        'parameters': List<double>.filled(21, 1),
        'desired_retention': 0.86,
      });
      expect(parsed, isNotNull);
      expect(parsed!.parameters, hasLength(21));
      expect(parsed.desiredRetention, 0.86);
    });

    test('accepts legacy weights key and rejects wrong vector length', () {
      final parsed = FsrsSettings.tryParse({
        'weights': List<int>.filled(21, 2),
      });
      expect(parsed?.parameters.first, 2.0);
      expect(
        FsrsSettings.tryParse({
          'weights': [1, 2, 3],
        }),
        isNull,
      );
    });
  });
}

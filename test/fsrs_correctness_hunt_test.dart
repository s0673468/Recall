// Scheduling fields only; no stored cards, content or live transport.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart'
    show
        Rating,
        defaultParameters,
        lowerBoundsParameters,
        upperBoundsParameters;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

import 'support/fsrs6_synthetic_logs.dart';

ReviewCard _card(Map<String, dynamic> scheduling) => ReviewCard.fromJson({
  'id': 701,
  'guid': 'synthetic-fsrs-golden',
  'deck_id': 1,
  'reps': 0,
  'lapses': 0,
  ...scheduling,
});

Map<String, dynamic> _next(ReviewOutcome out) => {
  'state': out.state,
  'stability': out.stability,
  'difficulty': out.difficulty,
  'due': out.due.toIso8601String(),
  'last_review': out.reviewedAt.toIso8601String(),
  'reps': out.reps,
  'lapses': out.lapses,
};

void main() {
  for (final scenario in fsrs6SyntheticLogs['scenarios'] as List) {
    test('Python FSRS 6.1.1 golden: ${scenario['name']}', () {
      final engine = FsrsEngine(
        parameters: (scenario['parameters'] as List).cast<double>(),
        desiredRetention: scenario['desired_retention'] as double,
      );
      var card = _card(scenario['seed'] as Map<String, dynamic>);
      for (final event in scenario['events'] as List) {
        final at = DateTime.parse(event['at'] as String);
        final rating = Rating.values[(event['rating'] as int) - 1];
        final expected = event['expected'] as Map<String, dynamic>;
        final out = engine.review(card, rating, now: at);
        expect(out.due.difference(at).inSeconds, expected['interval_seconds']);
        expect(out.stability, closeTo(expected['stability'] as double, 1e-9));
        expect(out.difficulty, closeTo(expected['difficulty'] as double, 1e-9));
        expect(out.state, expected['state']);
        expect(out.due.isUtc, isTrue);
        expect(engine.preview(card, now: at)[rating], out.due);
        // Exercise the durable reconstruction after every reference event.
        card = _card(
          jsonDecode(jsonEncode(_next(out))) as Map<String, dynamic>,
        );
      }
    });
  }

  test('offset/local review times preserve the golden UTC interval', () {
    final engine = FsrsEngine(parameters: [...defaultParameters]..[3] = 2.5);
    final utc = DateTime.utc(2026, 10, 23, 3, 5);
    final card = _card({'state': 0});
    for (final at in [
      utc,
      utc.toLocal(),
      DateTime.parse('2026-10-23T00:05:00-03:00'),
    ]) {
      final out = engine.review(card, Rating.easy, now: at);
      expect(out.due, DateTime.utc(2026, 10, 25, 3, 5));
      expect(out.reviewedAt, utc);
      expect(engine.preview(card, now: at)[Rating.easy], out.due);
    }
  });

  group('invalid scheduler configuration', () {
    test('stored settings reject nonfinite weights', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          FsrsSettings.tryParse({
            'parameters': [...defaultParameters]..[0] = value,
          }),
          isNull,
        );
      }
    });

    for (final retention in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -0.1,
      0.0,
      1.0,
      1.1,
    ]) {
      test('retention $retention is rejected without changing scheduling', () {
        expect(
          () => FsrsEngine(desiredRetention: retention),
          throwsArgumentError,
        );
        final engine = FsrsEngine();
        final card = _card({'state': 0});
        final at = DateTime.utc(2026, 10, 23);
        final before = engine.preview(card, now: at);
        expect(
          () => engine.setDesiredRetention(retention),
          throwsArgumentError,
        );
        expect(engine.desiredRetention, 0.9);
        expect(engine.preview(card, now: at), before);
        expect(
          FsrsSettings.tryParse({
            'parameters': defaultParameters,
            'desired_retention': retention,
          }),
          isNull,
        );
      });
    }

    test('failed weight validation preserves the complete applied fit', () {
      final weights = [...defaultParameters]..[3] = 20;
      final engine = FsrsEngine();
      final fittedAt = DateTime.utc(2026, 10, 1);
      engine.configure(
        FsrsSettings(
          parameters: weights,
          desiredRetention: 0.85,
          fittedAt: fittedAt,
        ),
      );
      final card = _card({'state': 0});
      final at = DateTime.utc(2026, 10, 23);
      final before = engine.preview(card, now: at);
      expect(
        () => engine.configure(
          FsrsSettings(
            parameters: [...defaultParameters]..[2] = -1,
            desiredRetention: 0.8,
          ),
        ),
        throwsArgumentError,
      );
      expect(engine.parameters, weights);
      expect(engine.desiredRetention, 0.85);
      expect(engine.configurationStatus, FsrsConfigurationStatus.applied);
      expect(engine.fittedAt, fittedAt);
      expect(engine.preview(card, now: at), before);
      // This used to pick up the rejected weights and throw on the next edit.
      engine.setDesiredRetention(0.85);
      expect(engine.preview(card, now: at), before);
    });
  });

  test('optimizer accepts each exact FSRS-6 parameter bound', () {
    for (var i = 0; i < defaultParameters.length; i++) {
      for (final value in [
        lowerBoundsParameters[i],
        upperBoundsParameters[i],
      ]) {
        final parameters = [...defaultParameters]..[i] = value;
        final result = FsrsOptimizerResult.tryParse({
          'parameters': parameters,
          'desired_retention': 0.9,
        });
        expect(result?.parameters, parameters, reason: 'parameter $i = $value');
      }
    }
  });

  test(
    'out-of-bounds optimizer vectors are rejected before any transport',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://fsrs-golden.invalid',
        '',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('[]', 200);
        }),
      );
      addTearDown(client.dispose);
      for (final (index, value) in [
        (0, 0.0),
        (4, 11.0),
        (20, 0.0),
        (20, 0.9),
      ]) {
        final report = {
          'parameters': [...defaultParameters]..[index] = value,
          'desired_retention': 0.9,
        };
        expect(FsrsOptimizerResult.tryParse(report), isNull);
        await expectLater(
          RecallApi(client).applyFsrsOptimizerResult(
            report,
            approved: true,
            confirmation: RecallApi.fsrsApplyConfirmation,
          ),
          throwsA(isA<FsrsOptimizerApplyException>()),
        );
      }
      expect(requests, 0);
    },
  );
}

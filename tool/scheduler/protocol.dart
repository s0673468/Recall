// Pure Dart wire boundary. The scheduling implementation is the phone app's
// FsrsEngine, imported unchanged; this file contains no scheduling formulae.
import 'package:fsrs/fsrs.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

Map<String, dynamic> outcomeJson(ReviewOutcome outcome) => {
  'stability': outcome.stability,
  'difficulty': outcome.difficulty,
  'due': outcome.due.toIso8601String(),
  'state': outcome.state,
  'reps': outcome.reps,
  'lapses': outcome.lapses,
  'reviewedAt': outcome.reviewedAt.toIso8601String(),
  'rating': outcome.rating,
};

FsrsEngine configuredEngine(Map<String, dynamic> settings) {
  final parameters = settings['parameters'] as List?;
  final retention = (settings['desiredRetention'] as num?)?.toDouble() ?? 0.9;
  if (!retention.isFinite || retention <= 0 || retention >= 1) {
    throw ArgumentError('desiredRetention must be between 0 and 1');
  }
  if (parameters != null &&
      (parameters.length != 21 ||
          parameters.any(
            (value) => value is! num || !value.toDouble().isFinite,
          ))) {
    throw ArgumentError('parameters must contain 21 finite numbers');
  }
  final engine = FsrsEngine();
  engine.configure(
    FsrsSettings(
      parameters:
          parameters?.map((value) => (value as num).toDouble()).toList() ??
          defaultParameters,
      desiredRetention: retention,
      optimizerStatus: settings['optimizerStatus'] == 'suggested'
          ? FsrsConfigurationStatus.suggested
          : FsrsConfigurationStatus.applied,
    ),
  );
  return engine;
}

Object scheduleRequest(Map<String, dynamic> request) {
  if (request['operation'] == 'batch') {
    return (request['requests'] as List)
        .map(
          (value) => scheduleRequest(Map<String, dynamic>.from(value as Map)),
        )
        .toList();
  }
  final row = Map<String, dynamic>.from(request['card'] as Map);
  row['guid'] ??= 'synthetic-${row['id']}';
  row['last_review'] ??= row['lastReview'];
  final card = ReviewCard.fromRow(row);
  final now = DateTime.parse(request['now'] as String).toUtc();
  final engine = configuredEngine(
    Map<String, dynamic>.from((request['settings'] as Map?) ?? const {}),
  );
  switch (request['operation']) {
    case 'review':
      final rating = request['rating'];
      if (rating is! int || rating < 1 || rating > 4) {
        throw ArgumentError('rating must be an integer from 1 to 4');
      }
      return outcomeJson(
        engine.review(card, Rating.values[rating - 1], now: now),
      );
    case 'preview':
      return engine
          .preview(card, now: now)
          .entries
          .map(
            (entry) => {
              'rating': entry.key.value,
              'due': entry.value.toIso8601String(),
              'intervalSeconds':
                  entry.value.difference(now).inMicroseconds / 1000000,
            },
          )
          .toList();
    case 'retrievability':
      return engine.retrievability(card, now: now);
    default:
      throw ArgumentError('Unknown scheduler operation');
  }
}

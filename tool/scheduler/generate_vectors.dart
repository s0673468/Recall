// Invented inputs only. Deterministic PRNG is explicit so VM and JS generators
// can be reproduced without depending on Random's platform implementation.
import 'dart:convert';
import 'dart:io';
import 'package:fsrs/fsrs.dart';
import 'protocol.dart';

class SyntheticRandom {
  int value = 0x5eed2026;
  int next(int bound) {
    value = (1664525 * value + 1013904223) & 0xffffffff;
    // Low bits of an LCG cycle with powers of two; use upper bits so paired
    // rating/delay samples do not omit Again and Good from review histories.
    return (value >> 8) % bound;
  }
}

Map<String, dynamic> newCard(int id) => {
  'id': id,
  'state': 0,
  'stability': null,
  'difficulty': null,
  'due': null,
  'last_review': null,
  'reps': 0,
  'lapses': 0,
};

void main(List<String> args) {
  final random = SyntheticRandom();
  final vectors = <Map<String, dynamic>>[];
  final historyStates = <int>{};
  final historyRatings = <int>{};
  var historyLapseTransitions = 0;
  final dates = [
    '1999-12-31T23:59:59.999Z',
    '2000-02-29T03:00:00.000001Z',
    '2024-02-29T02:59:59.999Z',
    '2026-10-06T03:00:00.123456Z',
    '2038-01-19T03:14:07.000Z',
    '2099-12-31T23:59:59.999Z',
  ];
  void record(Map<String, dynamic> request, String coverage) {
    vectors.add({
      'request': request,
      'expected': scheduleRequest(request),
      'coverage': coverage,
    });
  }

  const histories = 3072;
  for (var history = 0; history < histories; history++) {
    var card = newCard(history + 1);
    var now = DateTime.parse(dates[history % dates.length]);
    final settings = <String, dynamic>{
      'desiredRetention': [0.7, 0.8, 0.9, 0.95, 0.97][history % 5],
      if (history % 3 == 0)
        'parameters': [
          for (var i = 0; i < defaultParameters.length; i++)
            defaultParameters[i] * (i < 4 ? 0.85 + (history % 7) * 0.05 : 1.0),
        ],
      if (history % 11 == 0) 'optimizerStatus': 'suggested',
    };
    // Varied review histories, including repeated same-day learning, late
    // reviews, lapses, and reviews exactly at the scheduled instant.
    for (var step = 0; step < 3 + history % 9; step++) {
      final rating = 1 + random.next(4);
      historyStates.add(card['state'] as int);
      historyRatings.add(rating);
      final request = <String, dynamic>{
        'operation': 'review',
        'card': card,
        'rating': rating,
        'now': now.toIso8601String(),
        'settings': settings,
      };
      record(request, 'history');
      final result = scheduleRequest(request) as Map<String, dynamic>;
      if ((result['lapses'] as int) > (card['lapses'] as int)) {
        historyLapseTransitions++;
      }
      card = {...card, ...result, 'last_review': result['reviewedAt']};
      now = DateTime.parse(
        result['due'] as String,
      ).add(Duration(minutes: [0, 1, 60, 1440, 43200][random.next(5)]));
    }
    for (var rating = 1; rating <= 4; rating++) {
      record({
        'operation': 'review',
        'card': card,
        'rating': rating,
        'now': now.toIso8601String(),
        'settings': settings,
      }, 'all-ratings');
    }
    if (history < 128) {
      record({
        'operation': 'preview',
        'card': card,
        'now': now.toIso8601String(),
        'settings': settings,
      }, 'preview');
      record({
        'operation': 'retrievability',
        'card': card,
        'now': now.toIso8601String(),
        'settings': settings,
      }, 'retrievability');
    }
  }
  // Reconstructed durable learning state, including the old inflated stability
  // quirk and exact 10-minute step boundary. Relearning always restores step 0.
  for (final state in [0, 1, 2, 3]) {
    for (final stability in [null, 0.0, 0.0001, 3.0, 120.0]) {
      for (final gap in [-60, 0, 60, 599, 600, 601, 86400]) {
        for (final rating in [1, 2, 3, 4]) {
          final last = DateTime.parse(dates[gap.abs() % dates.length]);
          final card = {
            ...newCard(900000 + vectors.length),
            'state': state,
            'stability': stability,
            'difficulty': 5.0,
            'reps': 25,
            'lapses': 4,
            'due': last.add(Duration(seconds: gap)).toIso8601String(),
            'last_review': last.toIso8601String(),
          };
          record({
            'operation': 'review',
            'card': card,
            'rating': rating,
            'now': last.add(const Duration(days: 1)).toIso8601String(),
          }, 'reconstruction');
        }
      }
    }
  }
  for (final state in [1, 2, 3]) {
    for (final field in ['due', 'last_review']) {
      for (final rating in [1, 2, 3, 4]) {
        final card = {
          ...newCard(950000 + vectors.length),
          'state': state,
          'stability': 2.0,
          'difficulty': 5.0,
          'due': dates[3],
          'last_review': dates[3],
          field: null,
        };
        record({
          'operation': 'review',
          'card': card,
          'rating': rating,
          'now': dates[3],
        }, 'missing-durable-field');
      }
    }
  }
  if (historyStates.length != 4 ||
      historyRatings.length != 4 ||
      historyLapseTransitions == 0) {
    throw StateError(
      'Synthetic histories must cover all states, ratings and lapses',
    );
  }
  final output = jsonEncode({
    'schema': 'recall.scheduler-vectors/v1',
    'seed': '0x5eed2026',
    'histories': histories,
    'fsrsVersion': '2.0.1',
    'vectorCount': vectors.length,
    'historyStates': (historyStates.toList()..sort()).join(','),
    'historyRatings': (historyRatings.toList()..sort()).join(','),
    'historyLapseTransitions': historyLapseTransitions,
    'vectors': vectors,
  });
  if (args.isEmpty) {
    stdout.writeln(output);
  } else {
    File(args.single).writeAsStringSync('$output\n');
    stderr.writeln(
      '${vectors.length} vectors from $histories synthetic histories',
    );
  }
}

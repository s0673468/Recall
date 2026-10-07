import 'package:flutter_test/flutter_test.dart';
import '../tool/scheduler/protocol.dart';

void main() {
  final card = <String, dynamic>{
    'id': 1,
    'state': 1,
    'stability': 120.0,
    'difficulty': 5.0,
    'reps': 3,
    'lapses': 0,
    'due': '2026-10-06T03:10:00.000Z',
    'last_review': '2026-10-06T03:00:00.000Z',
  };
  final request = <String, dynamic>{
    'operation': 'review',
    'card': card,
    'rating': 3,
    'now': '2026-10-06T03:10:00.000Z',
  };

  test(
    'wire bridge preserves reconstructed Good graduation and stability clamp',
    () {
      final result = scheduleRequest(request) as Map<String, dynamic>;
      expect(result['state'], 2);
      expect(result['reps'], 4);
      expect(result['stability'] as double, lessThan(10));
      expect(
        DateTime.parse(
          result['due'] as String,
        ).isAfter(DateTime.parse('2026-10-07T03:10:00.000Z')),
        isTrue,
      );
    },
  );
  test(
    'all interval previews equal chosen rating results at one fixed time',
    () {
      final previews =
          scheduleRequest({...request, 'operation': 'preview'}) as List;
      for (final preview in previews.cast<Map<String, dynamic>>()) {
        final result =
            scheduleRequest({...request, 'rating': preview['rating']}) as Map;
        expect(result['due'], preview['due']);
      }
    },
  );
  test(
    'suggested settings use phone defaults and alias lastReview is accepted',
    () {
      final alias = {...card, 'lastReview': card['last_review']}
        ..remove('last_review');
      expect(
        scheduleRequest({...request, 'card': alias}),
        scheduleRequest(request),
      );
      expect(
        scheduleRequest({
          ...request,
          'settings': {
            'desiredRetention': 0.97,
            'optimizerStatus': 'suggested',
          },
        }),
        scheduleRequest(request),
      );
    },
  );
  test('invalid rating and non-finite configuration fail closed', () {
    expect(
      () => scheduleRequest({...request, 'rating': 0}),
      throwsArgumentError,
    );
    expect(
      () => scheduleRequest({...request, 'rating': 2.5}),
      throwsArgumentError,
    );
    expect(
      () => scheduleRequest({
        ...request,
        'settings': {'desiredRetention': 1.0},
      }),
      throwsArgumentError,
    );
    expect(
      () => configuredEngine({
        'parameters': [double.nan],
      }),
      throwsArgumentError,
    );
  });
}

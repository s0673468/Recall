import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/domain/study_day.dart';

void main() {
  test(
    'generated study instants partition into contiguous, zone-independent days',
    () {
      final random = Random(20261117);
      for (var i = 0; i < 2000; i++) {
        final at = DateTime.utc(
          2020,
        ).add(Duration(minutes: random.nextInt(15 * 366 * 24 * 60)));
        final start = StudyDay.start(at);
        final end = StudyDay.end(at);
        expect(start.hour, 3);
        expect(end.difference(start), const Duration(days: 1));
        expect(StudyDay.contains(at, at), isTrue);
        expect(StudyDay.start(at.toLocal()), start);
        expect(StudyDay.start(start), start);
        expect(StudyDay.start(end), end);
        expect(StudyDay.contains(end, at), isFalse);
        expect(
          StudyDay.contains(
            start.subtract(const Duration(microseconds: 1)),
            at,
          ),
          isFalse,
        );
      }
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/retention_panel.dart';

void main() {
  for (final (passed, total, percent) in [
    (0, 200, 0),
    (1, 200, 1),
    (57, 200, 29),
    (113, 200, 57),
    (112, 200, 56),
    (114, 200, 57),
    (199, 200, 100),
    (200, 200, 100),
  ]) {
    test('headline rounds $passed/$total to $percent%', () {
      final now = DateTime(2026, 10, 22, 12);
      final log = [
        for (var i = 0; i < total; i++)
          ReviewLogEntry(at: now, rating: i < passed ? 3 : 1),
      ];

      expect(StatsService.tileStats(log, today: now).recall, '$percent%');
    });

    testWidgets('retention and cohorts round $passed/$total to $percent%', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RetentionPanel(
                summary: RetentionSummary(
                  windowDays: 30,
                  total: total * 2,
                  passed: passed * 2,
                  youngTotal: total,
                  youngPassed: passed,
                  matureTotal: total,
                  maturePassed: passed,
                ),
                windowDays: 30,
                onWindowChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('$percent%', skipOffstage: false), findsNWidgets(3));
      expect(
        find.text(
          '${passed * 2} of ${total * 2} scheduled reviews remembered.',
        ),
        findsOneWidget,
      );
      final meter = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('recall_retention_meter')),
      );
      expect(meter.value, passed / total);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a missing cohort displays a dash, not zero percent', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RetentionPanel(
            summary: const RetentionSummary(
              windowDays: 30,
              total: 1,
              passed: 1,
              youngTotal: 1,
              youngPassed: 1,
              matureTotal: 0,
              maturePassed: 0,
            ),
            windowDays: 30,
            onWindowChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('—', skipOffstage: false), findsOneWidget);
    expect(find.text('0%', skipOffstage: false), findsNothing);
  });
}

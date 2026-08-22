import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/widgets/recall_surfaces.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

void main() {
  testWidgets('benchmark hero is the elevated visual tier', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: const Scaffold(
          body: RecallHeroPanel(
            key: Key('hero'),
            child: Text('Most important thing'),
          ),
        ),
      ),
    );

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const Key('hero')),
        matching: find.byType(Container),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.gradient, isNotNull);
    expect(decoration.borderRadius, BorderRadius.circular(UiRadii.hero));
    expect(decoration.boxShadow, isEmpty);
  });

  testWidgets('metric strip remains readable on a narrow large-text phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: RecallMetricStrip(
              metrics: [
                RecallMetric('Due now', '128'),
                RecallMetric('New left', '20'),
                RecallMetric('Reviewed', '37'),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('128'), findsOneWidget);
    expect(find.text('Reviewed'), findsOneWidget);
  });

  testWidgets('grouped rows preserve comfortable touch targets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: Scaffold(
          body: RecallListGroup(
            children: [
              RecallListRow(
                key: const Key('row'),
                icon: Icons.school_outlined,
                title: 'Machine learning',
                subtitle: 'Part of automatic review',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const Key('row'))).height,
      greaterThanOrEqualTo(60),
    );
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });
}

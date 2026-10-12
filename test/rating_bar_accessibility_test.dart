import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:health_anki_flutter/features/review/presentation/widgets/rating_bar.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

const _ratings = [
  (Rating.again, 'Again'),
  (Rating.hard, 'Hard'),
  (Rating.good, 'Good'),
  (Rating.easy, 'Easy'),
];

void main() {
  testWidgets('each rating is an enabled semantic button that activates once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final events = <Rating>[];
      await _pumpRatingBar(tester, events);

      for (final (rating, label) in _ratings) {
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        final data = node.getSemanticsData();
        expect(data.label, label);
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(events, [rating]);
        events.clear();

        await tester.tap(find.widgetWithText(FilledButton, label));
        await tester.pumpAndSettle();
        expect(events, [rating]);
        events.clear();
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('locked ratings announce disabled and reject activation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final events = <Rating>[];
      await _pumpRatingBar(tester, events, enabled: false);

      for (final (_, label) in _ratings) {
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        final data = node.getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isFalse);
        expect(data.hasAction(SemanticsAction.tap), isFalse);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.tap(find.widgetWithText(FilledButton, label));
        await tester.pumpAndSettle();
        expect(events, isEmpty);
      }
    } finally {
      semantics.dispose();
    }
  });
}

Future<void> _pumpRatingBar(
  WidgetTester tester,
  List<Rating> events, {
  bool enabled = true,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildRecallTheme(),
    home: Scaffold(
      body: RatingBar(onRate: events.add, enabled: enabled),
    ),
  ),
);

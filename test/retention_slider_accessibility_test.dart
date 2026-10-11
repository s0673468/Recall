import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

void main() {
  for (final (retention, value, increased, decreased) in const [
    (0.70, '70%', '71%', '70%'),
    (0.90, '90%', '91%', '89%'),
    (0.97, '97%', '97%', '96%'),
  ]) {
    testWidgets('retention $value announces actual percentage and bounds', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final prefs = _MemoryPrefs(RecallPrefs(desiredRetention: retention));
        final controller = _EmptyReviewController();
        addTearDown(prefs.dispose);
        addTearDown(controller.dispose);
        await _pumpSettings(tester, prefs, controller);

        final data = _retentionSlider.evaluate().single.getSemanticsData();
        expect(data.flagsCollection.isSlider, isTrue);
        expect(data.value, value);
        expect(data.increasedValue, increased);
        expect(data.decreasedValue, decreased);
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
        expect(prefs.updates, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'semantic retention adjustments commit actual one percent steps',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final prefs = _MemoryPrefs(const RecallPrefs());
        final controller = _EmptyReviewController();
        addTearDown(prefs.dispose);
        addTearDown(controller.dispose);
        await _pumpSettings(tester, prefs, controller);

        for (final (action, expected) in [
          (SemanticsAction.increase, 0.91),
          (SemanticsAction.decrease, 0.90),
          (SemanticsAction.decrease, 0.89),
        ]) {
          tester.semantics.performAction(_retentionSlider, action);
          await tester.pumpAndSettle();
          expect(prefs.value.desiredRetention, closeTo(expected, 0.000001));
          expect(
            prefs.updates.last.desiredRetention,
            closeTo(expected, 0.000001),
          );
          expect(
            _retentionSlider.evaluate().single.getSemanticsData().value,
            '${(expected * 100).round()}%',
          );
        }
        expect(prefs.updates, hasLength(3));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );
}

SemanticsFinder get _retentionSlider => find.semantics.byPredicate(
  (node) => node.getSemanticsData().flagsCollection.isSlider,
);

Future<void> _pumpSettings(
  WidgetTester tester,
  _MemoryPrefs prefs,
  _EmptyReviewController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: SettingsScreen(prefs: prefs, controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

// These presentation doubles never construct an API, load preferences, start a
// session, or read a store. Unexpected access fails instead of using live state.
class _MemoryPrefs extends ChangeNotifier implements RecallPrefsController {
  _MemoryPrefs(this._value);

  RecallPrefs _value;
  final updates = <RecallPrefs>[];

  @override
  RecallPrefs get value => _value;

  @override
  Future<void> update(RecallPrefs next) async {
    _value = next;
    updates.add(next);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected prefs fixture access: ${invocation.memberName}',
  );
}

class _EmptyReviewController extends ChangeNotifier
    implements ReviewController {
  @override
  final engine = FsrsEngine();

  @override
  ReviewState get state => const ReviewState(loading: false);

  @override
  Null get currentUser => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected review fixture access: ${invocation.memberName}',
  );
}

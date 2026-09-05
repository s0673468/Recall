import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import '../tool/acceptance/recall_acceptance_fixture.dart';

void main() {
  testWidgets('phone settings keep controls usable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dependencies = await createSanitizedAcceptanceDependencies(
      scenario: AcceptanceScenario.rich,
      now: DateTime.utc(2026, 9, 5),
    );
    addTearDown(() {
      dependencies.dispose();
      (dependencies.api as SanitizedRecallApi).disposeFixture();
    });
    final prefs = dependencies.recallPrefs;
    await prefs.update(prefs.value.copyWith(newLimitDefault: 999));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SettingsScreen(
            prefs: prefs,
            controller: dependencies.reviewController,
            reminder: dependencies.studyReminder,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final increase = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton && widget.tooltip == 'Increase New cards / day',
    );
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(increase, 300, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(increase).onPressed, isNull);
    await tester.tap(find.byTooltip('Decrease New cards / day'));
    await tester.pumpAndSettle();
    expect(prefs.value.newLimitDefault, 998);

    await tester.scrollUntilVisible(
      find.text('Random'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Random'));
    await tester.pumpAndSettle();
    expect(prefs.value.newOrder, NewOrder.random);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Scheduler details'),
      350,
      scrollable: scrollable,
    );
    expect(find.byType(FsrsOptimizerStatusLine), findsNothing);
    await tester.tap(find.text('Scheduler details'));
    await tester.pumpAndSettle();
    expect(find.byType(FsrsOptimizerStatusLine), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Per-deck new-card limits'),
      350,
      scrollable: scrollable,
    );
    expect(find.text('Set override'), findsNothing);
    await tester.tap(find.text('Per-deck new-card limits'));
    await tester.pumpAndSettle();
    final setOverride = find.text('Set override').first;
    await tester.scrollUntilVisible(setOverride, 300, scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(setOverride);
    await tester.pumpAndSettle();
    expect(prefs.value.perDeck, containsValue(998));
    await tester.scrollUntilVisible(
      find.text('Use default'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use default'));
    await tester.pumpAndSettle();
    expect(prefs.value.perDeck, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

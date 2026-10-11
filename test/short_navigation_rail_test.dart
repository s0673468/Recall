import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

void main() {
  for (final textScale in [1.0, 2.0]) {
    testWidgets('short Android rail reaches Read at ${textScale}x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(700, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final selections = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Row(
                children: [
                  RecallNavigationRail(
                    selectedIndex: 0,
                    onDestinationSelected: selections.add,
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('Read'),
        80,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
      expect(selections, [3]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('branded rail keeps settings reachable beside scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var openedSettings = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: Scaffold(
          body: Row(
            children: [
              RecallNavigationRail(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                showBrand: true,
                onOpenSettings: () => openedSettings++,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('recall_rail_settings')));
    await tester.pumpAndSettle();
    expect(openedSettings, 1);
  });
}

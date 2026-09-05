import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/core/platform/recall_platform.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';

void main() {
  test('native iOS detection excludes the web build', () {
    expect(
      recallRunsAsNativeIos(isWeb: false, targetPlatform: TargetPlatform.iOS),
      isTrue,
    );
    expect(
      recallRunsAsNativeIos(isWeb: true, targetPlatform: TargetPlatform.iOS),
      isFalse,
    );
  });

  test('native Android detection excludes the web build', () {
    expect(
      recallRunsAsNativeAndroid(
        isWeb: false,
        targetPlatform: TargetPlatform.android,
      ),
      isTrue,
    );
    expect(
      recallRunsAsNativeAndroid(
        isWeb: true,
        targetPlatform: TargetPlatform.android,
      ),
      isFalse,
    );
    expect(
      recallRunsAsNativeMobile(
        isWeb: false,
        targetPlatform: TargetPlatform.android,
      ),
      isTrue,
    );
  });

  testWidgets('native iOS uses translucent Cupertino tab chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: RecallBottomNavigation(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            nativeIos: true,
          ),
        ),
      ),
    );

    final bar = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
    expect(bar.backgroundColor?.a, lessThan(1));
    expect(bar.items.map((item) => item.label), contains('Read'));
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'Material navigation highlights the destination without a filled pill',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: RecallBottomNavigation(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              nativeIos: false,
            ),
          ),
        ),
      );

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(4));
      expect(find.text('Read'), findsOneWidget);
      expect(find.byType(CupertinoTabBar), findsNothing);
      final theme = tester.widget<NavigationBarTheme>(
        find.ancestor(
          of: find.byType(NavigationBar),
          matching: find.byType(NavigationBarTheme),
        ),
      );
      expect(theme.data.indicatorColor, Colors.transparent);
    },
  );

  testWidgets('wide Android surfaces use an adaptive navigation rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              RecallNavigationRail(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(4));
    expect(find.text('Study'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(rail.indicatorColor, Colors.transparent);
  });

  test('settings navigation uses the platform-appropriate transition', () {
    final iosRoute = buildRecallPageRoute<void>(
      nativeIos: true,
      builder: (_) => const SizedBox(),
    );
    final webRoute = buildRecallPageRoute<void>(
      nativeIos: false,
      builder: (_) => const SizedBox(),
    );

    expect(iosRoute, isA<CupertinoPageRoute<void>>());
    expect(webRoute, isA<MaterialPageRoute<void>>());
  });
}

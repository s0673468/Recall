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

  testWidgets('web keeps the existing Material navigation bar', (tester) async {
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

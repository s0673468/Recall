import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('web feedback adapter is a complete no-op', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final haptics = ReviewHaptics.forPlatform(
      isWeb: true,
      targetPlatform: TargetPlatform.iOS,
    );

    haptics
      ..reveal()
      ..rating()
      ..undo()
      ..completion();
    await tester.pump();

    expect(calls, isEmpty);
  });

  testWidgets('native iOS maps each review moment to a distinct impact', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final haptics = ReviewHaptics.forPlatform(
      isWeb: false,
      targetPlatform: TargetPlatform.iOS,
    );

    haptics
      ..reveal()
      ..rating()
      ..undo()
      ..completion();
    await tester.pump();

    expect(calls.map((call) => call.arguments), [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.heavyImpact',
    ]);
  });
}

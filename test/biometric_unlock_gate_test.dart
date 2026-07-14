import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/auth/presentation/widgets/biometric_unlock_gate.dart';

class _FakeBiometricPrompt implements RecallBiometricPrompt {
  _FakeBiometricPrompt({this.available = true, List<bool>? results})
    : _results = results ?? [true];

  bool available;
  final List<bool> _results;
  int promptCount = 0;

  @override
  Future<bool> get canAuthenticate async => available;

  @override
  Future<bool> authenticate() async {
    final index = promptCount < _results.length
        ? promptCount
        : _results.length - 1;
    promptCount += 1;
    return _results[index];
  }

  @override
  Future<void> cancel() async {}
}

void main() {
  test('Recall biometric lock is native mobile only', () {
    expect(
      supportsRecallBiometricUnlock(
        isWeb: false,
        targetPlatform: TargetPlatform.iOS,
      ),
      isTrue,
    );
    expect(
      supportsRecallBiometricUnlock(
        isWeb: false,
        targetPlatform: TargetPlatform.android,
      ),
      isTrue,
    );
    expect(
      supportsRecallBiometricUnlock(
        isWeb: true,
        targetPlatform: TargetPlatform.iOS,
      ),
      isFalse,
    );
    expect(
      supportsRecallBiometricUnlock(
        isWeb: false,
        targetPlatform: TargetPlatform.macOS,
      ),
      isFalse,
    );
  });

  testWidgets('hides Recall until device authentication succeeds', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt();

    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockGate(
          prompt: prompt,
          child: const Text('private recall data'),
        ),
      ),
    );

    expect(find.text('private recall data'), findsNothing);
    await tester.pumpAndSettle();

    expect(prompt.promptCount, 1);
    expect(find.text('private recall data'), findsOneWidget);
  });

  testWidgets('cancelled authentication stays locked and can be retried', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(results: [false, true]);
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockGate(
          prompt: prompt,
          child: const Text('private recall data'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('private recall data'), findsNothing);
    await tester.tap(find.text('Unlock Recall'));
    await tester.pumpAndSettle();

    expect(prompt.promptCount, 2);
    expect(find.text('private recall data'), findsOneWidget);
  });

  testWidgets('backgrounding relocks without losing mounted study state', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(results: [true, true]);
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockGate(prompt: prompt, child: const _CounterView()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('count 0'));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('count 1'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(prompt.promptCount, 2);
    expect(find.text('count 1'), findsOneWidget);
  });

  testWidgets('locking clears focus from hidden Recall inputs', (tester) async {
    final prompt = _FakeBiometricPrompt(results: [true, true]);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockGate(
          prompt: prompt,
          child: Scaffold(body: TextField(focusNode: focusNode)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('unavailable device auth never exposes Recall data', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(available: false);
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockGate(
          prompt: prompt,
          child: const Text('private recall data'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('private recall data'), findsNothing);
    expect(find.text('Device authentication is not available'), findsOneWidget);
    expect(prompt.promptCount, 0);
  });

  testWidgets('locked-screen sign-out reports a pending-sync failure', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(results: [false]);
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockGate(
          prompt: prompt,
          onSignOut: () async => throw StateError('pending study actions'),
          child: const Text('private recall data'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.textContaining('pending study actions'), findsOneWidget);
    expect(find.text('private recall data'), findsNothing);
  });
}

class _CounterView extends StatefulWidget {
  const _CounterView();

  @override
  State<_CounterView> createState() => _CounterViewState();
}

class _CounterViewState extends State<_CounterView> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TextButton(
        onPressed: () => setState(() => count += 1),
        child: Text('count $count'),
      ),
    );
  }
}

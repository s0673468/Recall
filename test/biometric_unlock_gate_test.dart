import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/auth/presentation/widgets/biometric_unlock_gate.dart';

class _FakeBiometricPrompt implements RecallBiometricPrompt {
  _FakeBiometricPrompt({
    this.available = true,
    List<bool>? results,
    this.authenticateOverride,
  }) : _results = results ?? [true];

  bool available;
  final List<bool> _results;
  final Future<bool> Function()? authenticateOverride;
  int promptCount = 0;
  int cancelCount = 0;

  @override
  Future<bool> get canAuthenticate async => available;

  @override
  Future<bool> authenticate() async {
    promptCount += 1;
    final override = authenticateOverride;
    if (override != null) return override();
    final index = promptCount < _results.length
        ? promptCount - 1
        : _results.length - 1;
    return _results[index];
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}

class _FakeElapsedTime {
  Duration value = Duration.zero;

  Duration call() => value;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

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
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: BiometricUnlockGate(
          prompt: prompt,
          child: const Text('private recall data'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('private recall data'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(prompt.promptCount, 1);
    expect(find.text('private recall data'), findsNothing);

    await tester.tap(find.text('Unlock Recall'));
    await tester.pumpAndSettle();

    expect(prompt.promptCount, 2);
    expect(find.text('private recall data'), findsOneWidget);
  });

  testWidgets('app switching uses a privacy cover without prompting again', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(results: [true]);
    final elapsedTime = _FakeElapsedTime();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: BiometricUnlockGate(
          prompt: prompt,
          elapsedTime: elapsedTime.call,
          child: const _CounterView(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('count 0'));
    await tester.pump();

    elapsedTime.value = const Duration(minutes: 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('count 1'), findsNothing);
    expect(find.byKey(const Key('recall_privacy_cover')), findsOneWidget);

    elapsedTime.value = const Duration(minutes: 5, seconds: 59);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(prompt.promptCount, 1);
    expect(find.text('count 1'), findsOneWidget);
    expect(find.byKey(const Key('recall_privacy_cover')), findsNothing);
  });

  testWidgets(
    'resume at five minutes locks and starts authentication automatically',
    (tester) async {
      final prompt = _FakeBiometricPrompt(results: [true, true]);
      final elapsedTime = _FakeElapsedTime();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: BiometricUnlockGate(
            prompt: prompt,
            elapsedTime: elapsedTime.call,
            child: const _CounterView(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('count 0'));
      await tester.pump();

      elapsedTime.value = const Duration(minutes: 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('count 1'), findsNothing);
      expect(find.byKey(const Key('recall_privacy_cover')), findsOneWidget);

      elapsedTime.value = const Duration(minutes: 7);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(prompt.promptCount, 2);
      expect(find.text('count 1'), findsOneWidget);
      expect(find.text('Unlock Recall'), findsNothing);
    },
  );

  testWidgets(
    'failed automatic reauthentication leaves the locked fallback available',
    (tester) async {
      final prompt = _FakeBiometricPrompt(results: [true, false]);
      final elapsedTime = _FakeElapsedTime();
      await tester.pumpWidget(
        MaterialApp(
          home: BiometricUnlockGate(
            prompt: prompt,
            elapsedTime: elapsedTime.call,
            child: const Text('private recall data'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      elapsedTime.value = const Duration(minutes: 5);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(prompt.promptCount, 2);
      expect(find.text('private recall data'), findsNothing);
      expect(
        find.text('Recall stayed locked because authentication was cancelled.'),
        findsOneWidget,
      );
      expect(find.text('Unlock Recall'), findsOneWidget);
    },
  );

  testWidgets(
    'gate rebuild while covered does not reset the reauthentication clock',
    (tester) async {
      final prompt = _FakeBiometricPrompt(results: [true, true]);
      final originalElapsedTime = _FakeElapsedTime();
      final replacementElapsedTime = _FakeElapsedTime();

      Widget buildGate(RecallElapsedTime elapsedTime) => MaterialApp(
        home: BiometricUnlockGate(
          key: const ValueKey('recall-biometric-gate'),
          prompt: prompt,
          elapsedTime: elapsedTime,
          child: const Text('private recall data'),
        ),
      );

      await tester.pumpWidget(buildGate(originalElapsedTime.call));
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      originalElapsedTime.value = const Duration(minutes: 5);

      await tester.pumpWidget(buildGate(replacementElapsedTime.call));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(prompt.promptCount, 2);
      expect(find.text('private recall data'), findsOneWidget);
    },
  );

  testWidgets(
    'native authentication lifecycle churn does not cancel or duplicate prompts',
    (tester) async {
      final result = Completer<bool>();
      final prompt = _FakeBiometricPrompt(
        authenticateOverride: () => result.future,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BiometricUnlockGate(
            prompt: prompt,
            child: const Text('private recall data'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(prompt.promptCount, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(prompt.promptCount, 1);
      expect(prompt.cancelCount, 0);

      result.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('private recall data'), findsOneWidget);
    },
  );

  testWidgets(
    'successful authentication while backgrounded stays privacy covered',
    (tester) async {
      final result = Completer<bool>();
      final prompt = _FakeBiometricPrompt(
        authenticateOverride: () => result.future,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BiometricUnlockGate(
            prompt: prompt,
            child: const Text('private recall data'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      result.complete(true);
      await tester.pumpAndSettle();

      expect(prompt.promptCount, 1);
      expect(find.text('private recall data'), findsNothing);
      expect(find.byKey(const Key('recall_privacy_cover')), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(prompt.promptCount, 1);
      expect(find.text('private recall data'), findsOneWidget);
      expect(find.byKey(const Key('recall_privacy_cover')), findsNothing);
    },
  );

  testWidgets('builder placement covers routes above the home screen', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(results: [true, false]);
    final elapsedTime = _FakeElapsedTime();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        builder: (context, navigator) => BiometricUnlockGate(
          prompt: prompt,
          elapsedTime: elapsedTime.call,
          child: navigator!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const Scaffold(body: Text('private pushed route')),
              ),
            ),
            child: const Text('open private route'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open private route'));
    await tester.pumpAndSettle();
    expect(find.text('private pushed route'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    elapsedTime.value = const Duration(minutes: 5);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(prompt.promptCount, 2);
    expect(find.text('private pushed route'), findsNothing);
    expect(find.text('Recall is locked'), findsOneWidget);
    expect(find.text('Unlock Recall'), findsOneWidget);
  });

  testWidgets('background privacy cover clears focus from Recall inputs', (
    tester,
  ) async {
    final prompt = _FakeBiometricPrompt(results: [true]);
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
    expect(find.byKey(const Key('recall_privacy_cover')), findsOneWidget);
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
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
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

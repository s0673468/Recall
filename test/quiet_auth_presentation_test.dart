import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';
import 'package:health_anki_flutter/vendored/health_flutter_shared.dart'
    show AuthGate, AuthGateModel, SignOutButton, SignOutButtonVariant;

void main() {
  testWidgets('auth presentation follows the ambient flat Recall theme', (
    tester,
  ) async {
    final source = ChangeNotifier();
    addTearDown(source.dispose);
    final model = AuthGateModel(
      source: source,
      submitting: () => false,
      errorText: () => null,
      signIn: ({required email, required password}) async {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: AuthGate(
          model: model,
          appName: 'Recall',
          subtitle: 'Spaced repetition',
        ),
      ),
    );
    final decorations = tester.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    );
    expect(
      decorations
          .where((widget) => widget.decoration is BoxDecoration)
          .every(
            (widget) => (widget.decoration as BoxDecoration).gradient == null,
          ),
      isTrue,
    );
    expect(
      decorations.any(
        (widget) =>
            widget.decoration == const BoxDecoration(color: UiColors.canvas),
      ),
      isTrue,
    );
    expect(
      decorations.any(
        (widget) =>
            widget.decoration is ShapeDecoration &&
            (widget.decoration as ShapeDecoration).color == UiColors.panel,
      ),
      isTrue,
    );
    final initial = tester.widget<Text>(find.text('R'));
    expect(initial.style!.color, UiColors.canvas);
    expect(
      tester.widget<Text>(find.text('Spaced repetition')).style!.color,
      UiColors.textMuted,
    );
    expect(find.text('Create account'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the themed sign-in form preserves input and submission behavior',
    (tester) async {
      final source = ChangeNotifier();
      addTearDown(source.dispose);
      var busy = false;
      String? error;
      String? notice;
      final submissions = <({String email, String password})>[];
      final model = AuthGateModel(
        source: source,
        submitting: () => busy,
        errorText: () => error,
        noticeText: () => notice,
        signIn: ({required email, required password}) async {
          submissions.add((email: email, password: password));
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: AuthGate(model: model, appName: 'Recall'),
        ),
      );
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.first).autofillHints, [
        AutofillHints.email,
      ]);
      expect(tester.widget<TextField>(fields.at(1)).autofillHints, [
        AutofillHints.password,
      ]);
      expect(tester.widget<TextField>(fields.at(1)).obscureText, isTrue);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(submissions, isEmpty);
      await tester.enterText(fields.first, '  learner@example.invalid  ');
      await tester.enterText(fields.at(1), ' spaced password ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(submissions, [
        (email: 'learner@example.invalid', password: ' spaced password '),
      ]);
      busy = true;
      source.notifyListeners();
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(find.text('Signing in…'), findsOneWidget);
      busy = false;
      notice = 'Check your email';
      source.notifyListeners();
      await tester.pump();
      expect(
        tester.widget<Text>(find.text(notice)).style!.color,
        UiColors.success,
      );
      error = 'Could not sign in';
      source.notifyListeners();
      await tester.pump();
      expect(
        tester.widget<Text>(find.text(error)).style!.color,
        UiColors.danger,
      );
      expect(find.text(notice), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('optional account creation keeps its existing callback', (
    tester,
  ) async {
    final source = ChangeNotifier();
    addTearDown(source.dispose);
    var signedIn = 0;
    var created = 0;
    final model = AuthGateModel(
      source: source,
      submitting: () => false,
      errorText: () => null,
      signIn: ({required email, required password}) async => signedIn++,
      signUp: ({required email, required password}) async => created++,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: AuthGate(model: model, appName: 'Recall'),
      ),
    );
    await tester.tap(find.byType(ChoiceChip).at(1));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField).first,
      'learner@example.invalid',
    );
    await tester.enterText(find.byType(TextField).at(1), 'local test password');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(signedIn, 0);
  });

  testWidgets(
    'themed sign out still requires confirmation and respects cancel',
    (tester) async {
      var signedOut = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: SignOutButton(
              onSignOut: () async => signedOut++,
              variant: SignOutButtonVariant.text,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<TextButton>(find.byType(TextButton))
            .style!
            .foregroundColor!
            .resolve({}),
        UiColors.textMuted,
      );
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(signedOut, 0);
      expect(find.text('Sign out?'), findsOneWidget);
      expect(
        tester
            .widgetList<Material>(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Material),
              ),
            )
            .any((material) => material.color == UiColors.panel),
        isTrue,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(signedOut, 0);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Sign out'),
        ),
      );
      await tester.pumpAndSettle();
      expect(signedOut, 1);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}

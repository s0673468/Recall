import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/rating_bar.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UI widgets', () {
    testWidgets('rating buttons omit scheduling estimates', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RatingBar(onRate: (_) {})),
        ),
      );

      expect(
        tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(RatingBar),
                matching: find.byType(Text),
              ),
            )
            .map((text) => text.data),
        ['Again', 'Hard', 'Good', 'Easy'],
      );
      expect(find.bySemanticsLabel('Again'), findsOneWidget);
      expect(find.bySemanticsLabel('Easy'), findsOneWidget);
    });

    testWidgets('RatingBar shows all four ratings and reports taps', (
      tester,
    ) async {
      Rating? tapped;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: RatingBar(onRate: (r) => tapped = r)),
        ),
      );
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);

      for (final (label, rating) in [
        ('Again', Rating.again),
        ('Hard', Rating.hard),
        ('Good', Rating.good),
        ('Easy', Rating.easy),
      ]) {
        await tester.tap(find.text(label));
        expect(tapped, rating);
      }
    });

    testWidgets('CardFace renders plain text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: 'What is backprop?',
              hasLatex: false,
              style: TextStyle(),
            ),
          ),
        ),
      );
      expect(find.textContaining('backprop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CardFace renders inline LaTeX without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: r'Embedding: vocab \(=5000\), dim \([32,10]\)',
              hasLatex: true,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('CardFace keeps punctuation with preceding inline LaTeX', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: r'Write the formula in terms of \(Q, K, V\).',
              hasLatex: true,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pump();

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), contains('\u2060.'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('StudyScreen reveals answers only from the button', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: FakeRecallApi([
          testCard(front: 'Complete: nos __ felizes.', back: 'eramos'),
        ]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      expect(find.byKey(const Key('recall_queue_strip')), findsOneWidget);
      expect(find.byKey(const Key('recall_study_card')), findsOneWidget);
      final studyCard = tester.widget<Container>(
        find.byKey(const Key('recall_study_card')),
      );
      final studyDecoration = studyCard.decoration! as BoxDecoration;
      expect(studyDecoration.gradient, isNull);
      expect(studyDecoration.color, UiColors.panel);
      expect(find.text('Question'), findsNothing);
      expect(find.text('Answer'), findsNothing);
      expect(find.text('Tap to reveal'), findsNothing);
      expect(find.text('Show answer'), findsOneWidget);
      expect(find.textContaining('eramos'), findsNothing);

      await tester.tap(
        find
            .descendant(
              of: find.byKey(const Key('recall_study_card')),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      await tester.pump();
      expect(find.textContaining('eramos'), findsNothing);
      await tester.tap(find.byKey(const Key('recall_study_card_footer')));
      await tester.pump();
      expect(find.textContaining('eramos'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      expect(find.textContaining('eramos'), findsOneWidget);
      expect(find.text('Question'), findsNothing);
      expect(find.text('Answer'), findsNothing);
    });

    testWidgets('StudyScreen supports review keyboard shortcuts', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        for (var id = 1; id <= 5; id++)
          testCard(id: id, front: 'Question $id', back: 'Answer $id'),
      ]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      expect(api.applied, isEmpty);

      final ratingKeys = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
      ];
      for (var index = 0; index < ratingKeys.length; index++) {
        expect(find.text('Show answer'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(find.text('Answer ${index + 1}'), findsOneWidget);

        await tester.sendKeyEvent(ratingKeys[index]);
        await tester.pumpAndSettle();
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Good'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(api.applied.map((entry) => entry['rating']), [
        Rating.again.value,
        Rating.hard.value,
        Rating.good.value,
        Rating.easy.value,
        Rating.good.value,
      ]);
      // The inline sync notice is transient; advance its documented lifetime.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('StudyScreen reparses revised content for the same card', (
      tester,
    ) async {
      await loadVisualFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        testCard(
          id: 508,
          front: '<b>Original prompt</b>',
          back: '{{c1::Original answer}} detail',
        ),
      ]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: RepaintBoundary(
            key: const Key('visual_benchmark_boundary'),
            child: Scaffold(body: StudyScreen(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Original prompt'), findsOneWidget);

      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Original answer'), findsOneWidget);

      api.queue[0] = testCard(
        id: 508,
        front: '<i>Revised prompt</i>',
        back: '{{c1::Revised answer}} detail',
      );
      await controller.refresh();
      await tester.pumpAndSettle();

      expect(find.textContaining('Revised prompt'), findsOneWidget);
      expect(find.textContaining('Original prompt'), findsNothing);
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Revised answer'), findsOneWidget);
      expect(find.textContaining('Original answer'), findsNothing);
      await captureVisual(tester, 'study-content-refresh');
    });

    testWidgets('StudyScreen fills in the cloze on flip (plain-summary back)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      // Real-data shape: the answer lives ONLY in the front's {{cN::}} markup;
      // the back is a separate plain summary with no deletion.
      final controller = ReviewController(
        api: FakeRecallApi([
          testCard(
            id: 507,
            front: '{{c1::mitochondria}} is the powerhouse',
            back: 'A cell organelle.',
          ),
        ]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      // Question side: deletion hidden, answer nowhere on screen.
      expect(find.textContaining('mitochondria'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      // Answer side: the FRONT fills in its deletion (the back is just the
      // summary), so the deleted word is now visible.
      expect(find.textContaining('mitochondria'), findsOneWidget);
      expect(find.textContaining('A cell organelle'), findsOneWidget);
    });

  });
}

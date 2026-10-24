import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<({ReviewController controller, FakeRecallApi api})> pumpStudy(
    WidgetTester tester, {
    int cards = 2,
    bool readingInput = false,
    double scale = 1,
    Size size = const Size(800, 700),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api =
        FakeRecallApi([
            for (var id = 1; id <= cards; id++)
              testCard(id: id, front: 'Synthetic question $id'),
          ])
          ..failApplyReview = true
          ..failApplyFlag = true;
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      clock: () => DateTime.utc(2026, 10, 24, 12),
    );
    addTearDown(controller.dispose);
    await controller.load();
    // Keep ratings unsent so their durable local count and Undo can be checked.
    api.beforeQueue = () async => throw StateError('Synthetic offline fetch');
    await controller.refresh();
    final study = StudyScreen(controller: controller, nativeIos: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: readingInput
                ? Row(
                    children: [
                      Expanded(child: study),
                      const Expanded(child: TextField()),
                    ],
                  )
                : study,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller: controller, api: api);
  }

  testWidgets('Space reveals then rates Good without revealing the next card', (
    tester,
  ) async {
    final (:controller, :api) = await pumpStudy(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.state.showBack, isTrue);
    expect(await controller.store.outbox(), isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final pending = await controller.store.outbox();
    expect(pending, hasLength(1));
    expect(pending.single['rating'], Rating.good.value);
    expect(pending.single['card_id'], 1);
    expect(controller.state.current?.id, 2);
    expect(controller.state.showBack, isFalse);
    expect(find.text('1 done'), findsOneWidget);
    expect(api.applied, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held Space is consumed without rating or scrolling', (
    tester,
  ) async {
    final (:controller, api: _) = await pumpStudy(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.state.showBack, isTrue);
    expect(await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space), isTrue);
    await tester.pumpAndSettle();
    expect(await controller.store.outbox(), isEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pumpWidget(const SizedBox());
  });

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.shiftLeft,
  ]) {
    testWidgets('${modifier.keyLabel} combinations leave study unchanged', (
      tester,
    ) async {
      final (:controller, api: _) = await pumpStudy(tester);
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(controller.state.showBack, isFalse);
      controller.flip();
      await tester.pumpAndSettle();
      for (final key in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(await controller.store.outbox(), isEmpty);
      expect(controller.state.current?.id, 1);
      await tester.sendKeyUpEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pumpAndSettle();
      expect(
        (await controller.store.outbox()).single['rating'],
        Rating.good.value,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Space activates the focused Like button on an answer', (
    tester,
  ) async {
    final (:controller, api: _) = await pumpStudy(tester);
    controller.flip();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.currentLiked, isTrue);
    expect(find.text('Liked · keep this style'), findsOneWidget);
    expect(controller.state.current?.id, 1);
    expect(await controller.store.outbox(), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.currentLiked, isFalse);
    expect(find.text('Like removed'), findsOneWidget);
    expect(controller.state.reviewedToday, 0);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reading input keeps its keys and clicking Study restores Space',
    (tester) async {
      final (:controller, api: _) = await pumpStudy(tester, readingInput: true);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '1234');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pumpAndSettle();
      expect(controller.state.showBack, isFalse);
      expect(await controller.store.outbox(), isEmpty);
      await tester.tap(find.text('Synthetic question 1'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(controller.state.showBack, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(controller.state.current?.id, 2);
      expect(controller.state.reviewedToday, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'completion keeps daily count and last dislike feedback at ${scale}x',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final (:controller, api: _) = await pumpStudy(
          tester,
          scale: scale,
          size: const Size(320, 740),
        );
        await tester.tap(find.text('Show answer'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Good'));
        await tester.tap(find.text('Good'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('recall_flag_dislike')),
        );
        await tester.tap(find.byKey(const Key('recall_flag_dislike')));
        await tester.pumpAndSettle();
        expect(controller.state.isDone, isTrue);
        expect(controller.state.reviewedToday, 1);
        expect(find.text('1 done'), findsOneWidget);
        expect(find.text('Hidden until Sunday review'), findsOneWidget);
        expect(find.bySemanticsLabel('1 card reviewed today'), findsOneWidget);
        expect(
          tester
              .getSemantics(find.text('Hidden until Sunday review'))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(find.text('Hidden until Sunday review'), findsNothing);
        expect(find.text('1 done'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      },
    );
  }

  testWidgets('last rating and Undo retain the durable daily total', (
    tester,
  ) async {
    final (:controller, api: _) = await pumpStudy(tester, cards: 1);
    await tester.tap(find.text('Show answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();
    expect(controller.state.isDone, isTrue);
    expect(find.text('1 done'), findsOneWidget);
    await tester.tap(find.text('Undo last rating'));
    await tester.pumpAndSettle();
    expect(controller.state.current?.id, 1);
    expect(controller.state.showBack, isFalse);
    expect(find.text('0 done'), findsOneWidget);
    expect(await controller.store.outbox(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

// Keep the real controller, store and (in Chrome) origin-wide Web Locks.
// Browser promise callbacks need the real event loop: pumpAndSettle alone only
// drains Flutter's fake clock and can leave storage-dependent actions parked.
Future<void> _act(
  WidgetTester tester,
  ReviewController controller,
  Future<void> Function() action,
) async {
  await tester.runAsync(() async {
    await action();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (controller.rateInFlight ||
        controller.likeInFlight ||
        controller.undoInFlight) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Study action did not finish within five seconds');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pumpAndSettle();
}

Future<({ReviewController controller, FakeRecallApi api})> _pumpStudy(
  WidgetTester tester, {
  int cards = 2,
  bool catchUp = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(800, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final now = DateTime.utc(2026, 10, 24, 12);
  final api = FakeRecallApi([
    for (var id = 1; id <= cards; id++)
      testCard(id: id, state: 2, due: now.subtract(const Duration(days: 1))),
  ])..failApplyFlag = true;
  final store = LocalReviewStore();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    clock: () => now,
  );
  addTearDown(controller.dispose);
  await tester.runAsync(() async {
    if (catchUp) {
      await store.saveCatchUpState(
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2026-10-24',
          completedToday: 19,
        ),
      );
    }
    await controller.load();
    // Preserve never-sent ratings for exact durable rating/Undo assertions.
    api.beforeQueue = () async => throw StateError('Synthetic offline fetch');
    await controller.refresh();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: Scaffold(
        body: StudyScreen(controller: controller, nativeIos: false),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(controller.state.offline, isTrue);
  expect(find.text('Show answer'), findsOneWidget);
  return (controller: controller, api: api);
}

void main() {
  group('fixture study acceptance', () {
    testWidgets('Space reveals, second Space saves exactly one Good', (
      tester,
    ) async {
      final (:controller, :api) = await _pumpStudy(tester);
      await _act(
        tester,
        controller,
        () => tester.sendKeyEvent(LogicalKeyboardKey.space),
      );
      expect(controller.state.showBack, isTrue);
      expect(find.text('Good'), findsOneWidget);
      expect(await tester.runAsync(controller.store.outbox), isEmpty);

      await _act(
        tester,
        controller,
        () => tester.sendKeyEvent(LogicalKeyboardKey.space),
      );
      final pending = (await tester.runAsync(controller.store.outbox))!;
      expect(pending, hasLength(1));
      expect(pending.single['rating'], Rating.good.value);
      expect(pending.single['card_id'], 1);
      expect(controller.state.current?.id, 2);
      expect(controller.state.showBack, isFalse);
      expect(find.text('Show answer'), findsOneWidget);
      expect(find.text('1 done'), findsOneWidget);
      expect(api.applied, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    final ratings = {
      LogicalKeyboardKey.digit1: Rating.again,
      LogicalKeyboardKey.digit2: Rating.hard,
      LogicalKeyboardKey.digit3: Rating.good,
      LogicalKeyboardKey.digit4: Rating.easy,
    };
    for (final entry in ratings.entries) {
      testWidgets(
        '${entry.key.keyLabel} saves ${entry.value.name} only after reveal',
        (tester) async {
          final (:controller, api: _) = await _pumpStudy(tester);
          await _act(tester, controller, () => tester.sendKeyEvent(entry.key));
          expect(controller.state.current?.id, 1);
          expect(await tester.runAsync(controller.store.outbox), isEmpty);
          await _act(
            tester,
            controller,
            () => tester.sendKeyEvent(LogicalKeyboardKey.space),
          );
          await _act(tester, controller, () => tester.sendKeyEvent(entry.key));
          final pending = (await tester.runAsync(controller.store.outbox))!;
          expect(pending, hasLength(1));
          expect(pending.single['rating'], entry.value.value);
          expect(pending.single['card_id'], 1);
          expect(controller.state.current?.id, 2);
          expect(controller.state.showBack, isFalse);
          expect(find.text('1 done'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      'Like toggles; dislike hides and Undo restores without a rating',
      (tester) async {
        final (:controller, api: _) = await _pumpStudy(tester);
        final like = find.byKey(const Key('recall_flag_like'));
        await _act(tester, controller, () => tester.tap(like));
        expect(controller.currentLiked, isTrue);
        expect(find.text('Liked · keep this style'), findsOneWidget);
        expect(tester.widget<IconButton>(like).isSelected, isTrue);
        expect(
          (await tester.runAsync(
            controller.store.flagOutbox,
          ))!.single['reason'],
          'like',
        );
        await _act(tester, controller, () => tester.tap(like));
        // Unlike withdraws its durable intent in the serialized background
        // flag flush; joining it avoids racing the acknowledgement assertion.
        await tester.runAsync(controller.syncPending);
        await tester.pumpAndSettle();
        expect(controller.currentLiked, isFalse);
        expect(find.text('Like removed'), findsOneWidget);
        expect(await tester.runAsync(controller.store.flagOutbox), isEmpty);

        await _act(
          tester,
          controller,
          () => tester.tap(find.byKey(const Key('recall_flag_dislike'))),
        );
        expect(controller.state.current?.id, 2);
        expect(find.text('Hidden until Sunday review'), findsOneWidget);
        expect(
          (await tester.runAsync(
            controller.store.flagOutbox,
          ))!.single['reason'],
          'dislike',
        );
        await _act(
          tester,
          controller,
          () => tester.tap(find.byTooltip('Undo')),
        );
        expect(controller.state.current?.id, 1);
        expect(controller.state.showBack, isFalse);
        expect(await tester.runAsync(controller.store.flagOutbox), isEmpty);
        expect(await tester.runAsync(controller.store.hiddenCardIds), isEmpty);
        expect(await tester.runAsync(controller.store.outbox), isEmpty);
        expect(find.text('0 done'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final catchUp in [false, true]) {
      for (final reason in ['dislike', 'delete']) {
        testWidgets(
          '$reason completion offers Undo hide (catch-up: $catchUp)',
          (tester) async {
            final (:controller, api: _) = await _pumpStudy(
              tester,
              cards: 1,
              catchUp: catchUp,
            );
            await _act(
              tester,
              controller,
              () => tester.tap(find.byKey(Key('recall_flag_$reason'))),
            );
            expect(controller.state.isDone, isTrue);
            expect(
              find.text(catchUp ? 'Session complete' : 'All caught up'),
              findsOneWidget,
            );
            expect(find.text('Undo hide'), findsOneWidget);
            expect(find.text('Undo last rating'), findsNothing);
            // The label follows the undo record, even after feedback expires.
            await tester.pump(const Duration(seconds: 4));
            await tester.pumpAndSettle();
            expect(find.text('Undo hide'), findsOneWidget);
            await _act(
              tester,
              controller,
              () => tester.tap(find.text('Undo hide')),
            );
            expect(controller.state.current?.id, 1);
            expect(controller.state.showBack, isFalse);
            expect(find.text('Show answer'), findsOneWidget);
            expect(
              await tester.runAsync(controller.store.hiddenCardIds),
              isEmpty,
            );
            expect(await tester.runAsync(controller.store.flagOutbox), isEmpty);
            expect(find.text('0 done'), findsOneWidget);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }

      testWidgets(
        'rating after hide Undo keeps rating wording (catch-up: $catchUp)',
        (tester) async {
          final (:controller, api: _) = await _pumpStudy(
            tester,
            cards: 1,
            catchUp: catchUp,
          );
          await _act(
            tester,
            controller,
            () => controller.hideCurrent('dislike'),
          );
          await _act(tester, controller, controller.undo);
          await _act(
            tester,
            controller,
            () => tester.tap(find.text('Show answer')),
          );
          await _act(tester, controller, () => tester.tap(find.text('Good')));
          expect(find.text('Undo last rating'), findsOneWidget);
          expect(find.text('Undo hide'), findsNothing);
          await _act(
            tester,
            controller,
            () => tester.tap(find.text('Undo last rating')),
          );
          expect(controller.state.current?.id, 1);
          expect(find.text('0 done'), findsOneWidget);
          expect(await tester.runAsync(controller.store.outbox), isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_test_harness.dart';

class _HeldFlagStore extends LocalReviewStore {
  final release = Completer<void>();
  int submissions = 0;

  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) async {
    submissions++;
    await release.future;
    return super.enqueueFlag(entry);
  }
}

void main() {
  for (final cancelWhileSaving in [false, true]) {
    testWidgets(
      cancelWhileSaving
          ? 'a dismissed flag sheet cannot pop Study when its save completes'
          : 'rapid flag selections save once and leave the Study route open',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final store = _HeldFlagStore();
        final api = FakeRecallApi([testCard(id: 903)])..failApplyFlag = true;
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
          controller.dispose();
        });
        await controller.load();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Invented parent route')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: StudyScreen(controller: controller, nativeIos: false),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Flag card'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Wrong'));
        await tester.pump();
        expect(store.submissions, 1);
        if (cancelWhileSaving) {
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.text('Confusing'));
          await tester.pump();
        }

        store.release.complete();
        await tester.pumpAndSettle();
        expect(find.byType(StudyScreen), findsOneWidget);
        expect(navigator.currentState!.canPop(), isTrue);
        expect(find.byType(BottomSheet), findsNothing);
        expect(store.submissions, 1);
        final flags = await store.flagOutbox();
        expect(flags, hasLength(1));
        expect(flags.single['reason'], 'wrong');
        expect(controller.state.current?.id, 903);
        expect(controller.state.reviewedThisSession, 0);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      },
    );
  }
}

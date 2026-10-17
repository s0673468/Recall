// A Retry/refresh that reads a corrupt local outbox must take the same recovery
// path as startup: a stable message, no escaped error, and the damaged outbox
// left byte-for-byte in place. Every value here is invented.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_test_harness.dart';

const _outboxKey = 'recall_outbox_v1';
const _corrupt = 'invented malformed outbox';
const _recoveryMessage =
    'Recall could not read the pending study actions. Reinstall '
    'only after exporting or recovering them.';

ReviewController _controller({FakeRecallApi? api}) {
  final controller = ReviewController(
    api: api ?? FakeRecallApi([testCard(id: 1, front: 'Invented front')]),
    engine: FsrsEngine(),
    store: LocalReviewStore(),
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<String?> _rawOutbox() async =>
    (await SharedPreferences.getInstance()).getString(_outboxKey);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'refresh after a corrupt-outbox startup keeps the recovery message',
    () async {
      SharedPreferences.setMockInitialValues({_outboxKey: _corrupt});
      final controller = _controller();

      await controller.initialize();
      expect(controller.state.error, _recoveryMessage);

      await controller.refresh();

      expect(controller.state.loading, isFalse);
      expect(controller.state.error, _recoveryMessage);
      expect(await _rawOutbox(), _corrupt);
    },
  );

  test(
    'refresh that finds the outbox newly corrupt keeps it in place',
    () async {
      SharedPreferences.setMockInitialValues({});
      // Deliveries fail, so the healthy session holds a queued review.
      final api = FakeRecallApi([
        testCard(id: 1, front: 'Invented front 1'),
        testCard(id: 2, front: 'Invented front 2'),
      ])..failApplyReview = true;
      final controller = _controller(api: api);
      await controller.initialize();
      controller.flip();
      await controller.rate(Rating.good);
      // Join the rating's background flush before damaging storage under it.
      await controller.syncPending();
      expect(controller.state.pendingSync, 1);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_outboxKey, _corrupt);

      await controller.refresh();

      expect(controller.state.loading, isFalse);
      expect(controller.state.error, _recoveryMessage);
      expect(await _rawOutbox(), _corrupt);
    },
  );

  testWidgets('tapping Retry on a corrupt outbox shows the recovery message', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_outboxKey: _corrupt});
    final controller = _controller();
    await tester.runAsync(controller.initialize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudyScreen(controller: controller, nativeIos: false),
        ),
      ),
    );
    expect(find.text(_recoveryMessage), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Retry'));
      // Let the async refresh settle; an escaped error fails the test.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(_recoveryMessage), findsOneWidget);
    expect(await tester.runAsync(_rawOutbox), _corrupt);
  });
}

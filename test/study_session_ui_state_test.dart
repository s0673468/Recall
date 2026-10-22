import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final hide in [false, true]) {
    final action = hide ? 'hide' : 'rating';

    test(
      'undo of a bonus $action after its due time preserves the count',
      () async {
        var now = DateTime.now().toUtc();
        final api = FakeRecallApi([])..failApplyFlag = true;
        final store = LocalReviewStore();
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => now,
        );
        addTearDown(controller.dispose);
        await controller.load();
        expect(controller.state.isDone, isTrue);

        // A learning card due soon is offered only in the bonus batch.
        api.queue.add(
          testCard(
            id: 901,
            state: 1,
            reps: 1,
            due: now.add(const Duration(minutes: 1)),
            lastReview: now.subtract(const Duration(minutes: 5)),
          ),
        );
        await controller.keepGoing();
        expect(controller.state.current?.id, 901);
        // Preserve this bonus card while offline, so the rating stays undoable.
        api.beforeQueue = () async =>
            throw StateError('invented offline fetch');
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        final before = controller.state.globalDueCount;
        expect(before, 0);

        if (hide) {
          await controller.hideCurrent('dislike');
        } else {
          controller.flip();
          await controller.rate(Rating.good);
        }
        expect(controller.state.globalDueCount, before);
        now = now.add(const Duration(minutes: 2));
        await controller.undo();

        expect(controller.state.current?.id, 901);
        expect(controller.state.showBack, isFalse);
        expect(controller.state.reviewedThisSession, 0);
        expect(controller.state.globalDueCount, before);
        expect(await store.outbox(), isEmpty);
      },
    );

    test(
      'undo of a $action cannot increase an already zero due count',
      () async {
        final now = DateTime.utc(2031, 1, 2, 12);
        final api = FakeRecallApi([
          testCard(
            id: 902,
            state: 2,
            due: now.subtract(const Duration(hours: 1)),
          ),
        ])..failApplyFlag = true;
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
          clock: () => now,
        );
        addTearDown(controller.dispose);
        await controller.load();
        // Queue and aggregate are separate reads; an aggregate can already be
        // zero when this device still has a due card on screen.
        expect(controller.state.globalDueCount, 0);
        api.beforeQueue = () async =>
            throw StateError('invented offline fetch');
        await controller.refresh();
        if (hide) {
          await controller.hideCurrent('dislike');
        } else {
          controller.flip();
          await controller.rate(Rating.good);
        }
        expect(controller.state.globalDueCount, 0);
        await controller.undo();

        expect(controller.state.current?.id, 902);
        expect(controller.state.globalDueCount, 0);
      },
    );
  }
}

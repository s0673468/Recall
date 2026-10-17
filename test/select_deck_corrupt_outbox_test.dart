// A deck switch that reads a corrupt local outbox must take the same recovery
// path as startup and Retry: a stable message, no escaped error, and the
// damaged outbox left byte-for-byte in place. Every value here is invented.
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

const _outboxKey = 'recall_outbox_v1';
const _corrupt = 'invented malformed outbox';
const _recoveryMessage =
    'Recall could not read the pending study actions. Reinstall '
    'only after exporting or recovering them.';

ReviewController _controller() {
  final controller = ReviewController(
    api: FakeRecallApi(
      [
        testCard(id: 1, front: 'Invented front 1', deckId: 1),
        testCard(id: 2, front: 'Invented front 2', deckId: 1),
        testCard(id: 3, front: 'Invented front 3', deckId: 2),
      ],
      decks: const [
        DeckRow(deckId: 1, name: 'Invented deck A'),
        DeckRow(deckId: 2, name: 'Invented deck B'),
      ],
    ),
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
    'switching deck with a corrupt outbox shows the recovery message',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = _controller();
      await controller.initialize();
      expect(controller.state.error, isNull);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_outboxKey, _corrupt);

      // An escaped LocalOutboxCorruptException fails the test here.
      await controller.selectDeck(2);

      expect(controller.state.loading, isFalse);
      expect(controller.state.error, _recoveryMessage);
      expect(controller.state.deckFilter, 2);
      expect(await _rawOutbox(), _corrupt);
    },
  );

  test(
    'switching deck on a healthy outbox still resets the session count',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = _controller();
      await controller.initialize();
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(controller.state.reviewedThisSession, 1);

      // refresh keeps the count; a deck switch starts a fresh session.
      await controller.refresh();
      expect(controller.state.reviewedThisSession, 1);

      await controller.selectDeck(2);

      expect(controller.state.error, isNull);
      expect(controller.state.deckFilter, 2);
      expect(controller.state.queue.single.id, 3);
      expect(controller.state.reviewedThisSession, 0);
    },
  );
}

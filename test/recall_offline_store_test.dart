import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Offline store', () {
    test('account namespaces isolate snapshots and durable outboxes', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.activateOwner('owner-a');
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'Owner A')],
        queue: [testCard(id: 101, front: 'owner-a-card')],
      );
      await store.enqueueReview({'card_id': 101, 'client_id': 'owner-a-event'});

      await store.activateOwner('owner-b');

      expect(await store.loadSnapshot(), isNull);
      expect(await store.outbox(), isEmpty);
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 2, name: 'Owner B')],
        queue: [testCard(id: 202, deckId: 2, front: 'owner-b-card')],
      );

      await store.activateOwner('owner-a');
      expect((await store.loadSnapshot())!.queue.single.front, 'owner-a-card');
      expect((await store.outbox()).single['client_id'], 'owner-a-event');
      await store.releaseOwner();
      expect(() => store.outbox(), throwsStateError);
    });

    test(
      'legacy local state is claimed by only the first upgraded owner',
      () async {
        final legacyCard = testCard(id: 303, front: 'legacy-owner-card');
        SharedPreferences.setMockInitialValues({
          'recall_snapshot_v1': jsonEncode({
            'savedAt': DateTime.utc(2026, 8, 23).toIso8601String(),
            'globalDueCount': 1,
            'globalDueUpdatedAt': DateTime.utc(2026, 8, 23).toIso8601String(),
            'decks': [const DeckRow(deckId: 3, name: 'Legacy').toJson()],
            'queue': [legacyCard.toJson()],
          }),
          'recall_outbox_v1': jsonEncode([
            {'card_id': 303, 'client_id': 'legacy-event'},
          ]),
        });
        final store = LocalReviewStore();

        await store.activateOwner('first-owner');
        expect((await store.loadSnapshot())!.queue.single.id, 303);
        expect((await store.outbox()).single['client_id'], 'legacy-event');

        await store.activateOwner('second-owner');
        expect(await store.loadSnapshot(), isNull);
        expect(await store.outbox(), isEmpty);
      },
    );

    test('signed-out background sync reports no work', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.activateOwner('owner-a');
      await store.releaseOwner();
      final controller = ReviewController(
        api: FakeRecallApi(const []),
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      final report = await controller.syncPendingInBackground();

      expect(report.attempted, 0);
      expect(report.delivered, 0);
      expect(report.pending, 0);
      expect(report.nativeResult, 'noData');
    });

    test(
      'corrupt review outbox fails closed instead of looking empty',
      () async {
        SharedPreferences.setMockInitialValues({
          'recall_outbox_v1': '{not valid json',
        });

        await expectLater(
          LocalReviewStore().outbox(),
          throwsA(isA<LocalOutboxCorruptException>()),
        );
      },
    );

    test('corrupt flag outbox fails closed instead of looking empty', () async {
      SharedPreferences.setMockInitialValues({'flag_outbox_v1': '[broken'});

      await expectLater(
        LocalReviewStore().flagOutbox(),
        throwsA(isA<LocalOutboxCorruptException>()),
      );
    });

    test('snapshot round-trips decks + queue', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final dueUpdatedAt = DateTime.utc(2026, 7, 13, 12, 30);
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        globalDueCount: 12,
        globalDueUpdatedAt: dueUpdatedAt,
        queue: [
          testCard(
            id: 7,
            state: 2,
            stability: 5,
            difficulty: 3,
            due: DateTime.utc(2026, 7, 1),
            hasLatex: true,
            front: r'vocab \(=5000\)',
          ),
        ],
      );
      final snap = await store.loadSnapshot();
      expect(snap, isNotNull);
      expect(snap!.decks.single.name, 'ML');
      expect(snap.queue.single.id, 7);
      expect(snap.queue.single.hasLatex, isTrue);
      expect(snap.queue.single.stability, 5);
      expect(snap.globalDueCount, 12);
      expect(snap.globalDueUpdatedAt, dueUpdatedAt);
    });

    test('all-decks and direct-deck snapshots stay independent', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [
          DeckRow(deckId: 1, name: 'ML'),
          DeckRow(deckId: 2, name: 'Math'),
        ],
        queue: [testCard(id: 1, deckId: 1), testCard(id: 2, deckId: 2)],
      );
      await store.saveSnapshot(
        deckId: 2,
        decks: const [
          DeckRow(deckId: 1, name: 'ML'),
          DeckRow(deckId: 2, name: 'Math'),
        ],
        queue: [testCard(id: 2, deckId: 2)],
      );

      expect((await store.loadSnapshot())!.queue.map((card) => card.id), [
        1,
        2,
      ]);
      expect(
        (await store.loadSnapshot(deckId: 2))!.queue.map((card) => card.id),
        [2],
      );
    });

    test('outbox enqueues and drains', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      expect(await store.enqueueReview({'card_id': 1, 'rating': 3}), 1);
      expect(await store.enqueueReview({'card_id': 2, 'rating': 4}), 2);
      expect((await store.outbox()).length, 2);
      // Simulate one synced (the flush removes only the delivered prefix,
      // so an entry enqueued mid-flush can never be clobbered).
      expect(await store.removeFirst(1), 1);
      final left = await store.outbox();
      expect(left.length, 1);
      expect(left.single['card_id'], 2);
      // removeFirst(0) is a pure count read.
      expect(await store.removeFirst(0), 1);
    });

    test('removeEntry drops only the matching queued review', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.enqueueReview({'card_id': 1, 'client_id': 11});
      await store.enqueueReview({'card_id': 2, 'client_id': 22});

      var result = await store.removeEntry(22);
      expect(result.removed, isTrue);
      expect(result.remaining, 1);
      expect((await store.outbox()).single['client_id'], 11);

      // Unknown id (already flushed): nothing removed, count untouched.
      result = await store.removeEntry(99);
      expect(result.removed, isFalse);
      expect(result.remaining, 1);
    });

    test('event ids are unique and share one stable install id', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();

      final ids = [for (var i = 0; i < 200; i++) await store.newEventId()];

      expect(ids.toSet(), hasLength(200));
      final install = await store.installId();
      expect(install, isNotEmpty);
      expect(ids.every((id) => id.startsWith('$install-')), isTrue);
      // The random suffix must actually vary — a platform where the entropy
      // collapsed (web's 32-bit shifts) would still pass a uniqueness check on
      // the counter alone, so assert the tails differ too.
      final tails = {for (final id in ids) id.split('-').last};
      expect(tails.length, greaterThan(190));
    });

    test('a second store on the same install reuses its id', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await LocalReviewStore().installId();
      // A fresh instance (app restart) must not mint a new identity.
      expect(await LocalReviewStore().installId(), first);
    });

    test('the install id survives sign-out', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final before = await store.installId();

      await store.clear();

      // It identifies the device, not the user: reviews still queued from a
      // previous session keep their uniqueness guarantee.
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(LocalReviewStore.installIdKey), before);
      expect(await LocalReviewStore().installId(), before);
    });

    test('clear() drops snapshot + outbox (sign-out)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [testCard(id: 1)],
      );
      await store.saveSnapshot(
        deckId: 1,
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [testCard(id: 1)],
      );
      await store.enqueueReview({'card_id': 1, 'rating': 3});
      await store.enqueueFlag({'card_id': 1, 'reason': 'wrong'});
      await store.clear();
      expect(await store.loadSnapshot(), isNull);
      expect(await store.loadSnapshot(deckId: 1), isNull);
      expect(await store.outbox(), isEmpty);
      expect(await store.flagOutbox(), isEmpty);
    });

    test('flag outbox enqueues, reads, and drains independently', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      // A flag write and a review write share the lock but stay separate lists.
      expect(await store.enqueueReview({'card_id': 1, 'rating': 3}), 1);
      expect(await store.enqueueFlag({'card_id': 1, 'reason': 'wrong'}), 1);
      expect(await store.enqueueFlag({'card_id': 2, 'reason': 'too_long'}), 2);
      expect((await store.flagOutbox()).length, 2);
      expect((await store.outbox()).length, 1); // review list untouched

      // Drain only the delivered prefix; a flag queued mid-flush survives.
      expect(await store.removeFirstFlag(1), 1);
      final left = await store.flagOutbox();
      expect(left.single['card_id'], 2);
      expect(left.single['reason'], 'too_long');
      // removeFirstFlag(0) is a pure count read; the review outbox is intact.
      expect(await store.removeFirstFlag(0), 1);
      expect((await store.outbox()).single['card_id'], 1);
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Executes the production outbox, with synthetic preferences. These focused
// regressions are not end-to-end schedules or evidence of native disk/browser
// persistence: the generated lab must separately drive actual apply_review.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final attemptFirst in [false, true]) {
    test('overlapping Undo/send: attemptFirst=$attemptFirst', () async {
      final store = LocalReviewStore();
      await store.activateOwner('synthetic-owner-a');
      await store.enqueueReview({'client_id': 'synthetic-race', 'card_id': 1});

      // Enqueue both operations before yielding; awaiting each operation before
      // starting the next would not exercise the shared serialization tail.
      late Future<bool> attempt;
      late Future<({bool removed, int remaining})> removal;
      if (attemptFirst) {
        attempt = store.markReviewAttempted('synthetic-race');
        removal = store.removeEntry('synthetic-race');
      } else {
        removal = store.removeEntry('synthetic-race');
        attempt = store.markReviewAttempted('synthetic-race');
      }
      final append = store.enqueueReview({
        'client_id': 'synthetic-next',
        'card_id': 2,
      });
      final queuedRead = store.outbox();

      expect(await attempt, attemptFirst);
      expect((await removal).removed, !attemptFirst);
      expect(await append, attemptFirst ? 2 : 1);
      final rows = await queuedRead;
      expect(rows.map((row) => row['client_id']).toList(), [
        if (attemptFirst) 'synthetic-race',
        'synthetic-next',
      ]);
      expect(rows.last['delivery_attempted'], isFalse);
      if (attemptFirst) expect(rows.first['delivery_attempted'], isTrue);

      final reopened = LocalReviewStore();
      await reopened.activateOwner('synthetic-owner-a');
      expect(await reopened.outbox(), rows);
      // An ambiguous send stays replayable after reopening; an undone entry
      // remains absent. Neither outcome permits a subsequent local removal.
      expect((await reopened.removeEntry('synthetic-race')).removed, isFalse);
      expect(await reopened.outbox(), rows);
    });
  }

  test('pinned old-owner send cannot poison new-owner Undo', () async {
    final store = LocalReviewStore();
    await store.activateOwner('synthetic-owner-a');
    final oldScope = store.activeOwnerScope!;
    await store.enqueueReview({'client_id': 'synthetic-same-id', 'card_id': 1});
    await store.activateOwner('synthetic-owner-b');
    await store.enqueueReview({'client_id': 'synthetic-same-id', 'card_id': 2});

    // Identical synthetic ids deliberately make namespace mistakes observable.
    final oldAttempt = store.markReviewAttempted(
      'synthetic-same-id',
      ownerScope: oldScope,
    );
    final newUndo = store.removeEntry('synthetic-same-id');
    expect(await oldAttempt, isTrue);
    expect((await newUndo).removed, isTrue);
    expect(await store.outbox(), isEmpty);
    final oldRows = await store.outbox(ownerScope: oldScope);
    expect(oldRows.single['card_id'], 1);
    expect(oldRows.single['delivery_attempted'], isTrue);

    final reopened = LocalReviewStore();
    await reopened.activateOwner('synthetic-owner-a');
    expect((await reopened.removeEntry('synthetic-same-id')).removed, isFalse);
    expect(await reopened.outbox(), oldRows);
    await reopened.activateOwner('synthetic-owner-b');
    expect(await reopened.outbox(), isEmpty);
  });

  test('legacy upgrade keeps uncertain review and removes only fresh Undo', () async {
    final legacy = {'client_id': 'synthetic-legacy', 'card_id': 1};
    SharedPreferences.setMockInitialValues({
      'recall_outbox_v1': jsonEncode([legacy]),
    });
    final store = LocalReviewStore();
    await store.activateOwner('synthetic-owner-a');
    await store.enqueueReview({'client_id': 'synthetic-fresh', 'card_id': 2});

    final legacyUndo = store.removeEntry('synthetic-legacy');
    final freshUndo = store.removeEntry('synthetic-fresh');
    final read = store.outbox();
    expect((await legacyUndo).removed, isFalse);
    expect((await freshUndo).removed, isTrue);
    expect(await read, [legacy]);

    // Upgrading/reopening must not reimport the removed fresh event or assign
    // the unscoped legacy source to a second account.
    final reopened = LocalReviewStore();
    await reopened.activateOwner('synthetic-owner-a');
    expect(await reopened.outbox(), [legacy]);
    await reopened.activateOwner('synthetic-owner-b');
    expect(await reopened.outbox(), isEmpty);
    await reopened.activateOwner('synthetic-owner-a');
    expect(await reopened.markReviewAttempted('synthetic-legacy'), isTrue);
    expect((await reopened.removeEntry('synthetic-legacy')).removed, isFalse);
  });
}

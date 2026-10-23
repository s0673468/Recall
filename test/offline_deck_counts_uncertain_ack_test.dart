// Synthetic scheduling metadata and in-process fakes only; no transport.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/offline_deck_counts.dart';

import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 23, 15);

  for (final isNew in [false, true]) {
    for (final landedBeforeRefresh in [false, true]) {
      test(
        '${isNew ? 'new' : 'due'} ACK invalidates uncertain coverage '
        'after ${landedBeforeRefresh ? 'lost ACK' : 'failed delivery'}',
        () async {
          SharedPreferences.setMockInitialValues({});
          final store = LocalReviewStore();
          final api = FakeRecallApi([])..deckCounts = {41: (due: 2, neu: 2)};
          OfflineDeckCounts loader(LocalReviewStore local) =>
              OfflineDeckCounts(api: api, store: local, clock: () => now);
          final counts = loader(store);
          await counts.load(offline: false);
          final review = <String, dynamic>{
            'client_id': 'synthetic-event',
            'card_id': 1,
            'deck_id': 41,
            'previous_state': isNew ? 0 : 2,
            'previous_due': now.toIso8601String(),
          };
          await store.enqueueReview(review);
          await store.markReviewAttempted(review['client_id']);
          final deliveredCounts = {
            41: (due: isNew ? 2 : 1, neu: isNew ? 1 : 2),
          };
          if (landedBeforeRefresh) api.deckCounts = deliveredCounts;
          expect(await counts.load(offline: false), api.deckCounts);
          expect(
            await loader(LocalReviewStore()).load(offline: true),
            api.deckCounts,
          );
          final prefs = await SharedPreferences.getInstance();
          final baseline =
              jsonDecode(prefs.getString('recall_deck_counts_v1')!)
                  as Map<String, dynamic>;

          // Retry succeeds after a restart. No aggregate can tell whether this
          // ACK was already covered, so invalidate rather than guess a count.
          final restartedStore = LocalReviewStore();
          expect(await restartedStore.removeAcknowledgedReviews([review]), 0);
          expect(await restartedStore.outbox(), isEmpty);
          api.failDeckCounts = true;
          await expectLater(counts.load(offline: true), throwsStateError);
          await expectLater(
            loader(LocalReviewStore()).load(offline: true),
            throwsStateError,
          );
          await expectLater(counts.load(offline: false), throwsStateError);

          api
            ..failDeckCounts = false
            ..deckCounts = deliveredCounts;
          expect(await counts.load(offline: false), deliveredCounts);
          // A duplicate ACK cannot invalidate or subtract from fresh truth.
          await restartedStore.removeAcknowledgedReviews([review]);
          expect(
            await loader(LocalReviewStore()).load(offline: true),
            deliveredCounts,
          );
          expect(baseline['settled'], isEmpty);
          expect(baseline['uncertain'], [1]);
        },
      );
    }
  }
}

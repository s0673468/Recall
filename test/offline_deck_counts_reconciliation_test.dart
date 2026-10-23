// Synthetic decks and local preference failures only; no transport or accounts.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/offline_deck_counts.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 23, 15);

Map<String, dynamic> _review(int card, {bool isNew = false}) => {
  'client_id': 'synthetic-event-$card',
  'card_id': card,
  'deck_id': 41,
  'previous_state': isNew ? 0 : 2,
  'previous_due': _now.toIso8601String(),
};

class _ControlledApi extends FakeRecallApi {
  _ControlledApi() : super([]);
  final requests = <Completer<Map<int, ({int due, int neu})>>>[];

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() {
    final request = Completer<Map<int, ({int due, int neu})>>();
    requests.add(request);
    return request.future;
  }
}

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.withData(const <String, Object>{});
  String? refuseSuffix;
  String? throwAfterCommitSuffix;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (refuseSuffix != null && key.endsWith(refuseSuffix!)) return false;
    final result = await super.setValue(type, key, value);
    if (throwAfterCommitSuffix != null &&
        key.endsWith(throwAfterCommitSuffix!)) {
      throw StateError('Synthetic lost local acknowledgement');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalReviewStore store;
  late FakeRecallApi api;
  late OfflineDeckCounts counts;

  OfflineDeckCounts restart() =>
      OfflineDeckCounts(api: api, store: LocalReviewStore(), clock: () => _now);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = LocalReviewStore();
    api = FakeRecallApi([])..deckCounts = {41: (due: 2, neu: 2)};
    counts = OfflineDeckCounts(api: api, store: store, clock: () => _now);
  });

  test(
    'a lost server ACK cannot subtract from a newer aggregate twice',
    () async {
      await counts.load(offline: false);
      final review = _review(1);
      await store.enqueueReview(review);
      await store.markReviewAttempted(review['client_id']);
      // The upload landed but its response was lost. Only card B remains due.
      api.deckCounts = {41: (due: 1, neu: 2)};
      expect(await counts.load(offline: false), {41: (due: 1, neu: 2)});
      expect(await counts.load(offline: false), {41: (due: 1, neu: 2)});
      expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
      expect(await store.outbox(), hasLength(1));
      // Replay acknowledges the same event. Fresh server truth replaces coverage.
      await store.removeAcknowledgedReviews([review]);
      expect(await counts.load(offline: false), api.deckCounts);
      expect(await restart().load(offline: true), api.deckCounts);
    },
  );

  test('an unaccepted pending upload still subtracts once', () async {
    await counts.load(offline: false);
    final review = _review(1);
    await store.enqueueReview(review);
    await store.markReviewAttempted(review['client_id']);
    // Same outbox state, but this time the upload never reached the server.
    expect(await counts.load(offline: false), {41: (due: 1, neu: 2)});
    expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
  });

  for (final isNew in [false, true]) {
    test(
      'a drained ${isNew ? 'new' : 'due'} review survives refresh failure',
      () async {
        await counts.load(offline: false);
        final review = _review(1, isNew: isNew);
        await store.enqueueReview(review);
        final expected = {41: (due: isNew ? 2 : 1, neu: isNew ? 1 : 2)};
        expect(await counts.load(offline: true), expected);
        await store.markReviewAttempted(review['client_id']);
        expect(await store.removeAcknowledgedReviews([review]), 0);
        api.failDeckCounts = true;
        expect(await counts.load(offline: false), expected);
        expect(await restart().load(offline: true), expected);
        expect(await store.outbox(), isEmpty);
        // A duplicate late ACK after fresh counts must not decrement again.
        api
          ..failDeckCounts = false
          ..deckCounts = expected;
        expect(await counts.load(offline: false), expected);
        await store.removeAcknowledgedReviews([review]);
        expect(await restart().load(offline: true), expected);
      },
    );
  }

  test('delivery before any overlay read still adjusts the cache', () async {
    await counts.load(offline: false);
    final review = _review(1);
    await store.enqueueReview(review);
    await store.removeAcknowledgedReviews([review]);
    expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
  });

  test(
    'partial delivery keeps pending reviews and undo in separate buckets',
    () async {
      await counts.load(offline: false);
      final delivered = _review(1);
      final pending = _review(2, isNew: true);
      await store.enqueueReview(delivered);
      await store.enqueueReview(pending);
      await store.removeAcknowledgedReviews([delivered]);
      expect(await restart().load(offline: true), {41: (due: 1, neu: 1)});
      await store.removeEntry(pending['client_id']);
      expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
    },
  );

  test(
    'a review delivered during an aggregate fetch invalidates the response',
    () async {
      await counts.load(offline: false);
      final controlled = _ControlledApi();
      final loader = OfflineDeckCounts(
        api: controlled,
        store: store,
        clock: () => _now,
      );
      final refreshing = loader.load(offline: false);
      final review = _review(1);
      await store.enqueueReview(review);
      await store.removeAcknowledgedReviews([review]);
      // This response started before the upload and still includes card A.
      controlled.requests.single.complete({41: (due: 2, neu: 2)});
      expect(await refreshing, {41: (due: 1, neu: 2)});
      expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
    },
  );

  test(
    'a review queued during a fetch prevents replacing its baseline',
    () async {
      await counts.load(offline: false);
      final controlled = _ControlledApi();
      final loader = OfflineDeckCounts(
        api: controlled,
        store: store,
        clock: () => _now,
      );
      final refreshing = loader.load(offline: false);
      await store.enqueueReview(_review(1));
      controlled.requests.single.complete({41: (due: 1, neu: 2)});
      expect(await refreshing, {41: (due: 1, neu: 2)});
      expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
    },
  );

  test(
    'without a baseline unresolved delivery leaves counts unavailable',
    () async {
      final review = _review(1);
      await store.enqueueReview(review);
      await store.markReviewAttempted(review['client_id']);
      await expectLater(counts.load(offline: false), throwsStateError);
      await expectLater(restart().load(offline: true), throwsStateError);
      await store.removeAcknowledgedReviews([review]);
      api.deckCounts = {41: (due: 1, neu: 2)};
      expect(await counts.load(offline: false), api.deckCounts);
    },
  );

  for (final failure in ['cache refusal', 'outbox refusal', 'lost cache ACK']) {
    test(
      '$failure keeps count settlement restart-safe and retryable',
      () async {
        final previous = SharedPreferencesStorePlatform.instance;
        SharedPreferences.resetStatic();
        final native = _Native();
        SharedPreferencesStorePlatform.instance = native;
        addTearDown(() {
          SharedPreferencesStorePlatform.instance = previous;
          SharedPreferences.resetStatic();
        });
        await counts.load(offline: false);
        final review = _review(1);
        await store.enqueueReview(review);
        if (failure == 'lost cache ACK') {
          native.throwAfterCommitSuffix = 'recall_deck_counts_v1';
        } else {
          native.refuseSuffix = failure == 'cache refusal'
              ? 'recall_deck_counts_v1'
              : 'recall_outbox_v1';
        }
        await expectLater(
          store.removeAcknowledgedReviews([review]),
          throwsA(anything),
        );
        expect(await store.outbox(), hasLength(1));
        expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
        native
          ..refuseSuffix = null
          ..throwAfterCommitSuffix = null;
        expect(await store.removeAcknowledgedReviews([review]), 0);
        api.failDeckCounts = true;
        expect(await counts.load(offline: false), {41: (due: 1, neu: 2)});
        expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
      },
    );
  }

  test(
    'settlement uses the first bucket of a repeatedly reviewed card',
    () async {
      await counts.load(offline: false);
      final first = _review(1, isNew: true);
      final later = {..._review(1), 'client_id': 'synthetic-later'};
      await store.enqueueReview(first);
      await store.enqueueReview(later);
      await store.removeAcknowledgedReviews([later]);
      expect(await restart().load(offline: true), {41: (due: 2, neu: 1)});
      await store.removeAcknowledgedReviews([first]);
      expect(await restart().load(offline: true), {41: (due: 2, neu: 1)});
    },
  );

  test(
    'another Store settling a review invalidates an in-flight fetch',
    () async {
      await counts.load(offline: false);
      final controlled = _ControlledApi();
      final loader = OfflineDeckCounts(api: controlled, store: store);
      final refreshing = loader.load(offline: false);
      final other = LocalReviewStore();
      final review = _review(1);
      await other.enqueueReview(review);
      await other.removeAcknowledgedReviews([review]);
      controlled.requests.single.complete({41: (due: 2, neu: 2)});
      expect(await refreshing, {41: (due: 1, neu: 2)});
      expect(await restart().load(offline: true), {41: (due: 1, neu: 2)});
    },
  );

  test(
    'old ambiguous cache is discarded until pending reviews settle',
    () async {
      SharedPreferences.setMockInitialValues({
        'recall_deck_counts_v1': jsonEncode({
          'fetchedAt': _now.toIso8601String(),
          'counts': {
            '41': {'due': 1, 'new': 2},
          },
        }),
      });
      final review = _review(1);
      await store.enqueueReview(review);
      await expectLater(counts.load(offline: true), throwsStateError);
      await expectLater(counts.load(offline: false), throwsStateError);
      await store.removeAcknowledgedReviews([review]);
      api.deckCounts = {41: (due: 1, neu: 2)};
      expect(await counts.load(offline: false), api.deckCounts);
      expect(await restart().load(offline: true), api.deckCounts);
    },
  );

  test('delayed owner-scoped ACK updates only its own baseline', () async {
    await store.activateOwner('synthetic-owner-a');
    final ownerA = store.activeOwnerScope;
    await counts.load(offline: false);
    final review = _review(1);
    await store.enqueueReview(review);
    await store.activateOwner('synthetic-owner-b');
    api.deckCounts = {41: (due: 9, neu: 0)};
    await counts.load(offline: false);
    await store.removeAcknowledgedReviews([review], ownerScope: ownerA);
    expect(await counts.load(offline: true), {41: (due: 9, neu: 0)});
    await store.activateOwner('synthetic-owner-a');
    expect(await counts.load(offline: true), {41: (due: 1, neu: 2)});
    await store.clear();
    await expectLater(counts.load(offline: true), throwsStateError);
  });
}

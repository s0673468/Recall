// Synthetic metadata and in-process fakes only; no card contents or transport.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/offline_deck_counts.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 23, 15);
Map<String, dynamic> _review(int card) => {
  'client_id': 'synthetic-$card',
  'card_id': card,
  'deck_id': 41,
  'previous_state': 2,
  'previous_due': _now.toIso8601String(),
};

class _FailingCountCache extends InMemorySharedPreferencesStore {
  _FailingCountCache() : super.withData(const <String, Object>{});
  bool fail = false;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (fail && key.endsWith('recall_deck_counts_v1')) {
      throw StateError('Synthetic count-cache failure');
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalReviewStore store;
  late FakeRecallApi api;
  late OfflineDeckCounts counts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = LocalReviewStore();
    api = FakeRecallApi([])..deckCounts = {41: (due: 2, neu: 1)};
    counts = OfflineDeckCounts(api: api, store: store, clock: () => _now);
  });

  test('a parked 23xxx review cannot freeze fresh online counts', () async {
    await counts.load(offline: false);
    await store.enqueueReview(_review(1));
    var attempts = 0;
    api.beforeApplyReview = () async {
      attempts++;
      throw const PostgrestException(
        message: 'Synthetic refusal',
        code: '23514',
      );
    };
    final controller = ReviewController(
      api: api,
      store: store,
      engine: FsrsEngine(),
      clock: () => _now,
    );
    addTearDown(controller.dispose);
    await controller.syncPending();
    expect(controller.state.syncErrors, 1);
    // A distinct, never-sent review is the only local online overlay.
    await store.enqueueReview(_review(2));
    api.deckCounts = {41: (due: 8, neu: 3)};
    expect(await counts.load(offline: false), {41: (due: 7, neu: 3)});
    await store.removeEntry('synthetic-2');
    await controller.syncPending();
    expect(attempts, 1);
    api.deckCounts = {41: (due: 9, neu: 4)};
    expect(await counts.load(offline: false), api.deckCounts);
    expect(
      await OfflineDeckCounts(
        api: api,
        store: LocalReviewStore(),
      ).load(offline: true),
      api.deckCounts,
    );
    expect(await store.outbox(), hasLength(1));
  });

  for (final malformed in [false, true]) {
    test(
      '${malformed ? 'malformed' : 'ambiguous'} identity cannot block or overlay online counts',
      () async {
        await counts.load(offline: false);
        // Conflicting identities can survive older producers/native storage;
        // current enqueue deduplication would collapse this fixture.
        await (await SharedPreferences.getInstance()).setString(
          'recall_outbox_v1',
          jsonEncode([
            {
              ..._review(1),
              'client_id': malformed ? '' : 'synthetic-conflict',
              'delivery_attempted': false,
            },
            if (!malformed)
              {
                ..._review(2),
                'client_id': 'synthetic-conflict',
                'delivery_attempted': false,
              },
          ]),
        );
        await store.enqueueReview(_review(3));
        api.deckCounts = {41: (due: 8, neu: 5)};
        expect(await counts.load(offline: false), {41: (due: 7, neu: 5)});
        expect(await store.outbox(), hasLength(malformed ? 2 : 3));
        await store.removeEntry('synthetic-3');
        expect(await counts.load(offline: true), api.deckCounts);
      },
    );
  }

  test(
    'online without v2 snapshot uses server and only unsent overlay',
    () async {
      await store.enqueueReview(_review(1));
      await store.markReviewAttempted('synthetic-1');
      await store.enqueueReview(_review(2));
      expect(await counts.load(offline: false), {41: (due: 1, neu: 1)});
      expect(
        await OfflineDeckCounts(
          api: api,
          store: LocalReviewStore(),
        ).load(offline: true),
        {41: (due: 1, neu: 1)},
      );
      expect(await store.outbox(), hasLength(2));
    },
  );

  test(
    'cache write exception cannot retain a server-confirmed review',
    () async {
      final previous = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      final native = _FailingCountCache();
      SharedPreferencesStorePlatform.instance = native;
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      });
      await counts.load(offline: false);
      final review = _review(1);
      await store.enqueueReview(review);
      native.fail = true;
      expect(await store.removeAcknowledgedReviews([review]), 0);
      expect(await LocalReviewStore().outbox(), isEmpty);
      await expectLater(counts.load(offline: true), throwsStateError);
      // Even persistent cache failures cannot prevent a fresh online result.
      api.deckCounts = {41: (due: 7, neu: 3)};
      expect(await counts.load(offline: false), api.deckCounts);
    },
  );
}

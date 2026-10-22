import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

import '../tool/fixtures/synthetic_native_offline_restart_main.dart';
import '../tool/fixtures/synthetic_recall_flow.dart';
import 'support/recall_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('removing a deck does not discard its pending review', () async {
    final removed = testCard(id: 1, deckId: 1);
    final decks = [
      const DeckRow(deckId: 1, name: 'Synthetic::Removed'),
      const DeckRow(deckId: 2, name: 'Synthetic::Kept'),
    ];
    final api = FakeRecallApi([
      removed,
      testCard(id: 2, deckId: 2),
    ], decks: decks)..failApplyReview = true;
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
    );
    addTearDown(controller.dispose);
    await enqueuePendingReview(store: store, api: api, card: removed);
    await controller.load();
    final pending = await store.outbox();
    decks.removeWhere((deck) => deck.deckId == 1);
    api.queue.removeWhere((card) => card.deckId == 1);
    await controller.refresh();
    await controller.selectDeck(2);
    expect(await store.outbox(), pending);
    expect(controller.state.pendingSync, 1);
    expect(controller.state.decks.map((deck) => deck.deckId), [2]);

    // A metadata deletion alone does not remove the review's card identity.
    api.failApplyReview = false;
    await controller.syncPending();
    expect(await store.outbox(), isEmpty);
    expect(api.server.reviewLog.single['card_id'], 1);
  });

  test(
    'rename and nesting preserve catch-up progress across deck switches',
    () async {
      final now = DateTime.utc(2026, 8, 5, 12);
      final decks = [
        const DeckRow(deckId: 1, name: 'Synthetic backlog'),
        const DeckRow(deckId: 2, name: 'Synthetic empty'),
      ];
      final api = FakeRecallApi([
        for (var id = 1; id <= 82; id++)
          testCard(
            id: id,
            state: 2,
            due: now.subtract(const Duration(hours: 1)),
          ),
      ], decks: decks);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load(deckId: 1);
      await controller.startCatchUp();
      final progress = await store.loadCatchUpState();
      decks[0] = const DeckRow(deckId: 1, name: 'Synthetic::Nested::Renamed');

      await controller.selectDeck(2);
      expect(controller.state.queue, isEmpty);
      expect(await store.loadCatchUpState(), progress);
      await controller.selectDeck(1);
      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.queue, hasLength(20));
      expect(controller.state.decks.first.name, 'Synthetic::Nested::Renamed');
      expect(await store.loadCatchUpState(), progress);
      expect(api.applied, isEmpty);
    },
  );

  test(
    'paginated counts converge after a synthetic review acknowledgement',
    () async {
      final transport = SyntheticNativeOfflineHttp([
        for (var id = 1; id <= 20; id++) syntheticCard(id),
      ], 'synthetic-owner')..onlineWrites = true;
      final client = SupabaseClient(
        'https://recall-bench.invalid',
        '',
        httpClient: MockClient(transport.respond),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final api = RecallApi(client);
      expect((await api.fetchDeckCounts())[1], (due: 20, neu: 0));
      expect(
        await api.applyReview({
          'client_id': 'synthetic-review',
          'card_id': 1,
          'guid': 'synthetic-card-1',
          'rating': 3,
        }),
        isNotNull,
      );
      expect((await api.fetchDeckCounts())[1], (due: 19, neu: 0));
    },
  );
}

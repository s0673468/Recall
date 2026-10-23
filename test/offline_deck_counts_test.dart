// Synthetic decks, preferences and in-process API only.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/offline_deck_counts.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 23, 15);
const _decks = [DeckRow(deckId: 41, name: 'Synthetic core')];

Map<String, dynamic> _entry(int id, int deck, int state, {DateTime? due}) => {
  'client_id': 'synthetic-$id-$state',
  'card_id': id,
  'deck_id': deck,
  'previous_state': state,
  'previous_due': due?.toIso8601String(),
};

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  ReviewState state = const ReviewState(loading: false, decks: _decks);
  void publish(ReviewState next) {
    state = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// reviewEntry is pure: this client cannot perform any transport or auth.
class _NoTransportClient implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('No transport in fixture');
}

class _EntryApi extends FakeRecallApi {
  _EntryApi(super.cards) : super(decks: _decks);
  @override
  Map<String, dynamic> reviewEntry(
    ReviewCard card,
    ReviewOutcome outcome, {
    int? elapsedMs,
  }) => RecallApi(
    _NoTransportClient(),
  ).reviewEntry(card, outcome, elapsedMs: elapsedMs);
}

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

class _UnreadableCache extends LocalReviewStore {
  @override
  Future<({Map<int, ({int due, int neu})> counts, DateTime fetchedAt})?>
  loadDeckCounts({required String? ownerScope}) =>
      throw StateError('Synthetic cache read failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalReviewStore store;
  late FakeRecallApi api;
  late OfflineDeckCounts counts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = LocalReviewStore();
    api = FakeRecallApi([])
      ..deckCounts = {41: (due: 3, neu: 2), 42: (due: 1, neu: 1)};
    counts = OfflineDeckCounts(api: api, store: store, clock: () => _now);
  });

  test(
    'offline restart overlays due/new reviews once per card and deck',
    () async {
      await counts.load(offline: false);
      await store.enqueueReview(_entry(1, 41, 2, due: _now));
      await store.enqueueReview(_entry(1, 41, 1, due: _now));
      await store.enqueueReview(_entry(2, 41, 0));
      await store.enqueueReview(_entry(3, 42, 2, due: _now));
      // Ahead/validation cards were not in the server due bucket at fetch time.
      await store.enqueueReview(
        _entry(4, 41, 2, due: _now.add(const Duration(days: 1))),
      );
      await store.enqueueReview({
        'card_id': 5,
        'client_id': 'synthetic-legacy',
      });
      final restarted = OfflineDeckCounts(
        api: api..failDeckCounts = true,
        store: LocalReviewStore(),
        clock: () => _now,
      );
      expect(await restarted.load(offline: true), {
        41: (due: 2, neu: 1),
        42: (due: 0, neu: 1),
      });
      expect(await restarted.load(offline: false), {
        41: (due: 2, neu: 1),
        42: (due: 0, neu: 1),
      });
      expect(await store.outbox(), hasLength(6));
    },
  );

  test(
    'undo removes the overlay; drained reviews use fresh server counts',
    () async {
      await counts.load(offline: false);
      final entry = _entry(1, 41, 0);
      await store.enqueueReview(entry);
      expect((await counts.load(offline: true))[41], (due: 3, neu: 1));
      await store.removeEntry(entry['client_id'] as String);
      expect((await counts.load(offline: true))[41], (due: 3, neu: 2));
      api.deckCounts = {41: (due: 1, neu: 0)};
      expect(await counts.load(offline: false), api.deckCounts);
      api.failDeckCounts = true;
      expect(await counts.load(offline: true), api.deckCounts);
    },
  );

  test(
    'overlay cannot make counts negative or manufacture absent decks',
    () async {
      api.deckCounts = {41: (due: 0, neu: 0)};
      await counts.load(offline: false);
      await store.enqueueReview(_entry(1, 41, 0));
      await store.enqueueReview(_entry(2, 41, 2, due: _now));
      await store.enqueueReview(_entry(3, 99, 0));
      expect(await counts.load(offline: true), {41: (due: 0, neu: 0)});
    },
  );

  test(
    'missing cache remains unavailable and cached counts are account scoped',
    () async {
      await expectLater(counts.load(offline: true), throwsStateError);
      await store.activateOwner('synthetic-owner-a');
      await counts.load(offline: false);
      await store.enqueueReview(_entry(1, 41, 0));
      await store.activateOwner('synthetic-owner-b');
      await expectLater(counts.load(offline: true), throwsStateError);
      await store.activateOwner('synthetic-owner-a');
      expect((await counts.load(offline: true))[41], (due: 3, neu: 1));
      await store.clear();
      await expectLater(counts.load(offline: true), throwsStateError);
    },
  );

  test('successful server reads do not depend on a readable cache', () async {
    final loader = OfflineDeckCounts(api: api, store: _UnreadableCache());
    expect(await loader.load(offline: false), api.deckCounts);
  });

  test(
    'overlapping responses cannot replace the newest cached counts',
    () async {
      final controlled = _ControlledApi();
      final loader = OfflineDeckCounts(api: controlled, store: store);
      final first = loader.load(offline: false);
      final firstResult = expectLater(first, throwsStateError);
      final second = loader.load(offline: false);
      controlled.requests.last.complete({41: (due: 1, neu: 0)});
      expect(await second, {41: (due: 1, neu: 0)});
      controlled.requests.first.complete({41: (due: 9, neu: 0)});
      await firstResult;
      expect(await loader.load(offline: true), {41: (due: 1, neu: 0)});
    },
  );

  test(
    'an owner change expires in-flight responses without caching them',
    () async {
      await store.activateOwner('synthetic-owner-a');
      final controlled = _ControlledApi();
      final loader = OfflineDeckCounts(api: controlled, store: store);
      final first = loader.load(offline: false);
      final firstResult = expectLater(first, throwsStateError);
      await store.activateOwner('synthetic-owner-b');
      controlled.requests.single.complete({41: (due: 9, neu: 0)});
      await firstResult;
      await expectLater(loader.load(offline: true), throwsStateError);
      await store.activateOwner('synthetic-owner-a');
      await expectLater(loader.load(offline: true), throwsStateError);
    },
  );

  testWidgets(
    'visible counts advance offline and undo without replacing decks',
    (tester) async {
      store = LocalReviewStore();
      api.deckCounts = {41: (due: 1, neu: 1)};
      final controller = _Controller();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecksScreen(
              controller: controller,
              api: api,
              store: store,
              onStudyDeck: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your core decks · 1 due · 1 new'), findsOneWidget);
      final entry = _entry(
        1,
        41,
        2,
        due: _now.subtract(const Duration(days: 1)),
      );
      await store.enqueueReview(entry);
      api.failDeckCounts = true;
      controller.publish(
        controller.state.copyWith(offline: true, pendingSync: 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your core decks · 0 due · 1 new'), findsOneWidget);
      await store.removeEntry(entry['client_id'] as String);
      controller.publish(controller.state.copyWith(pendingSync: 0));
      await tester.pumpAndSettle();
      expect(find.text('Your core decks · 1 due · 1 new'), findsOneWidget);
      // Reconnect can drain the outbox before a queue reload clears offline.
      await store.enqueueReview(entry);
      controller.publish(controller.state.copyWith(pendingSync: 1));
      await tester.pumpAndSettle();
      await store.removeFirst(1);
      api
        ..failDeckCounts = false
        ..deckCounts = {41: (due: 0, neu: 1)};
      controller.publish(controller.state.copyWith(pendingSync: 0));
      await tester.pumpAndSettle();
      expect(find.text('Your core decks · 0 due · 1 new'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'rating persists pre-rating deck metadata after queue pruning',
    () async {
      final card = testCard(id: 7, deckId: 41, state: 2, due: _now);
      api = _EntryApi([card])..deckCounts = {41: (due: 1, neu: 0)};
      final controller = ReviewController(
        api: api,
        store: store,
        engine: FsrsEngine(),
        clock: () => _now,
      );
      addTearDown(controller.dispose);
      await controller.load();
      // Keep replay in-flight so the durable entry can be inspected.
      final blocked = Completer<void>();
      api.beforeApplyReview = () => blocked.future;
      controller.flip();
      await controller.rate(Rating.good);
      final entry = (await store.outbox()).single;
      expect(entry['deck_id'], 41);
      expect(entry['previous_state'], 2);
      expect(entry['previous_due'], _now.toIso8601String());
      blocked.complete();
      await controller.syncPending();
    },
  );
}

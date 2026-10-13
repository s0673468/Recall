import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_acceptance_fixture.dart';

// Invented records and the .invalid fixture adapter only. Gate native storage,
// rather than replacing any LocalReviewStore behavior with a delayed override.
final _now = DateTime.utc(2026, 10, 13, 12);
const _waitLimit = Duration(seconds: 5);

ReviewCard _card(int id) => ReviewCard(
  id: id,
  guid: 'invented-reload-ack-$id',
  deckId: 1,
  front: 'Invented front $id',
  back: 'Invented back $id',
  hasLatex: false,
  stability: 4,
  difficulty: 5,
  due: _now.subtract(const Duration(days: 1)),
  state: 2,
  reps: 3,
  lapses: 0,
  lastReview: _now.subtract(const Duration(days: 5)),
  cloudSeen: true,
);

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> hold() async {
    entered.complete();
    await release.future;
  }

  Future<void> waitUntilEntered() => entered.future.timeout(_waitLimit);

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

class _NativePrefs extends InMemorySharedPreferencesStore {
  _NativePrefs() : super.empty();

  _Gate? reviewWrite;
  final acknowledgedOutboxes = <List<Map<String, dynamic>>>[];

  Set<String> durableClientIdsFor(int cardId) => {
    for (final outbox in acknowledgedOutboxes)
      for (final entry in outbox)
        if (entry['card_id'] == cardId) entry['client_id'] as String,
  };

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final isReviewOutbox = key.contains('recall_outbox_v1');
    if (isReviewOutbox) {
      final gate = reviewWrite;
      reviewWrite = null;
      if (gate != null) await gate.hold();
    }
    final written = await super.setValue(valueType, key, value);
    if (isReviewOutbox && written) {
      acknowledgedOutboxes.add(_entries(value as String));
    }
    return written;
  }
}

List<Map<String, dynamic>> _entries(String raw) => [
  for (final entry in jsonDecode(raw) as List)
    Map<String, dynamic>.from(entry as Map),
];

class _Api extends SanitizedRecallApi {
  _Api()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [_card(101), _card(102), _card(103)],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  _Gate? nextQueueRead;
  bool failNextQueue = false;
  final attemptedCardIds = <int>[];

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    final gate = nextQueueRead;
    final fail = failNextQueue;
    nextQueueRead = null;
    failNextQueue = false;
    if (gate != null) await gate.hold();
    if (fail) throw StateError('invented failed queue refresh');
    return super.fetchQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      newLimit: newLimit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    attemptedCardIds.add((entry['card_id'] as num).toInt());
    throw StateError('invented failed review delivery');
  }
}

class _Session {
  _Session(this.native, this.api, this.store, this.controller);

  final _NativePrefs native;
  final _Api api;
  final LocalReviewStore store;
  final ReviewController controller;
  final gates = <_Gate>[];
  final work = <Future<void>>[];

  _Gate gate() {
    final gate = _Gate();
    gates.add(gate);
    return gate;
  }

  Future<void> track(Future<void> future) {
    work.add(future);
    return future;
  }
}

Future<_Session> _session() async {
  final previousPlatform = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _NativePrefs();
  SharedPreferencesStorePlatform.instance = native;
  final api = _Api();
  final store = LocalReviewStore();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
    clock: () => _now,
  );
  final session = _Session(native, api, store, controller);
  addTearDown(() async {
    controller.dispose();
    for (final gate in session.gates) {
      gate.open();
    }
    try {
      await Future.wait([
        for (final future in session.work)
          future.catchError((Object _) {}),
      ]).timeout(_waitLimit);
      // Drain detached snapshot/flush work before replacing the global store.
      await store.outbox().timeout(_waitLimit);
      await store.flagOutbox().timeout(_waitLimit);
    } finally {
      api.disposeFixture();
      SharedPreferencesStorePlatform.instance = previousPlatform;
      SharedPreferences.resetStatic();
    }
  });
  // The fixture starts with an invented signed-in user. Activate that namespace
  // without emitting an auth event that could create an unrelated queue load.
  await store.activateOwner(api.currentUser!.id).timeout(_waitLimit);
  await controller.load(deckId: 1).timeout(_waitLimit);
  await store.outbox().timeout(_waitLimit);
  expect(controller.state.current?.id, 101);
  return session;
}

Future<void> _race({
  required bool delayQueueResponse,
  required bool failQueue,
}) async {
  final session = await _session();
  final controller = session.controller;
  final reviewAck = session.gate();
  final queueRead = session.gate();
  controller.flip();
  session.native.reviewWrite = reviewAck;
  final rating = session.track(controller.rate(Rating.good));
  await reviewAck.waitUntilEntered();

  // SharedPreferences has already updated its cache, but its native write
  // has not acknowledged durability. Reading through LocalReviewStore here
  // would wait on the real outbox lock that this test deliberately holds.
  final prefs = await SharedPreferences.getInstance().timeout(_waitLimit);
  final key = prefs.getKeys().singleWhere(
    (key) => key.contains('recall_outbox_v1'),
  );
  final cachedEntry = _entries(prefs.getString(key)!).single;
  expect(cachedEntry['card_id'], 101);
  final clientId = cachedEntry['client_id'] as String;
  expect(session.native.durableClientIdsFor(101), isEmpty);

  session.api.nextQueueRead = queueRead;
  session.api.failNextQueue = failQueue;
  final reload = session.track(controller.selectDeck(1));
  expect(controller.state.loading, isTrue);
  expect(controller.state.deckFilter, 1);
  expect(controller.state.current?.id, 101);
  expect(controller.state.index, 0);
  expect(controller.state.showBack, isTrue);
  expect(controller.state.reviewedThisSession, 0);
  expect(controller.rateInFlight, isTrue);
  // Even a second press during the unacknowledged commit must stay inert.
  await controller.rate(Rating.good).timeout(_waitLimit);
  expect(_entries(prefs.getString(key)!).single['client_id'], clientId);
  expect(session.native.durableClientIdsFor(101), isEmpty);

  // Production reload reads share the native write's lock, so the reload
  // cannot finish before this ack. Exercise an immediately available queue
  // response, then a response explicitly held until rating has settled.
  if (!delayQueueResponse) queueRead.open();
  reviewAck.open();
  if (delayQueueResponse) {
    await rating.timeout(_waitLimit);
    await queueRead.waitUntilEntered();
    expect(controller.rateInFlight, isFalse);
    queueRead.open();
  }
  await Future.wait([rating, reload]).timeout(_waitLimit);
  expect(session.api.attemptedCardIds, contains(101));

  // On the regressed head A is still revealed after the failed refresh, so
  // this ordinary press commits a second, different durable client id for A.
  await controller.rate(Rating.good).timeout(_waitLimit);
  final pending = await session.store.outbox().timeout(_waitLimit);
  expect(session.native.durableClientIdsFor(101), {clientId});
  expect(pending, hasLength(1));
  expect(pending.single['card_id'], 101);
  expect(pending.single['client_id'], clientId);
  expect(controller.state.current?.id, 102);
  expect(controller.state.showBack, isFalse);
  expect(controller.state.loading, isFalse);
  expect(controller.state.offline, failQueue);
  expect(controller.rateInFlight, isFalse);
}

void main() {
  test(
    'same-deck reload with immediate failure cannot rate native-acked A twice',
    () => _race(delayQueueResponse: false, failQueue: true),
  );
  test(
    'same-deck reload failing after rating settles cannot revive A',
    () => _race(delayQueueResponse: true, failQueue: true),
  );
  test(
    'successful same-deck reload excludes A after native rating acknowledgement',
    () => _race(delayQueueResponse: true, failQueue: false),
  );
}

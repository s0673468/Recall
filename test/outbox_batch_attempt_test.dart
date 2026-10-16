// Batched delivery marks: a drain closes the Undo window of many reviews in
// one native write instead of rewriting the whole outbox once per review.
// Invented cards and an in-memory native backend; no external service calls.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

import '../tool/fixtures/synthetic_native_outbox_cost_main.dart';
import '../tool/fixtures/synthetic_recall_flow.dart'
    show syntheticPendingReview;
import 'support/recall_acceptance_fixture.dart';
import 'support/recall_test_harness.dart';

const _outboxKey = 'flutter.recall_outbox_v1';

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> hold() async {
    entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

/// Counts acknowledged review-outbox writes. [crashAtWrite] holds that write
/// forever before the native ACK, as if the process died mid-write. The gates
/// hold the next outbox or catch-up write's ACK until opened.
class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.empty();

  int outboxWrites = 0;
  int outboxBytes = 0;
  int? crashAtWrite;
  int? refuseAtWrite;
  final crashed = Completer<void>();
  _Gate? outboxGate;
  _Gate? catchUpGate;

  /// The next outbox write commits, then throws; reads fail until cleared,
  /// so the controller cannot confirm the save.
  bool throwAfterCommit = false;
  bool failReads = false;

  void resetCounts() {
    outboxWrites = 0;
    outboxBytes = 0;
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) {
    if (failReads) throw StateError('Invented native read failure');
    return super.getAllWithParameters(parameters);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith(_outboxKey) && throwAfterCommit) {
      throwAfterCommit = false;
      await super.setValue(valueType, key, value);
      failReads = true;
      throw StateError('Invented write failure after commit');
    }
    if (key.contains(LocalReviewStore.catchUpKey)) {
      final gate = catchUpGate;
      catchUpGate = null;
      await gate?.hold();
    }
    if (key.startsWith(_outboxKey)) {
      final gate = outboxGate;
      outboxGate = null;
      await gate?.hold();
      final ordinal = outboxWrites + 1;
      if (ordinal == crashAtWrite) {
        crashed.complete();
        return Completer<bool>().future;
      }
      if (ordinal == refuseAtWrite) {
        refuseAtWrite = null;
        return false;
      }
      outboxWrites = ordinal;
      outboxBytes += utf8.encode(value as String).length;
    }
    return super.setValue(valueType, key, value);
  }

  /// Native truth of the one review outbox, bypassing every Dart-side cache.
  Future<List<Map<String, dynamic>>> outbox() async {
    final values = await getAll();
    final keys = values.keys.where((key) => key.startsWith(_outboxKey));
    final raw = keys.isEmpty ? null : values[keys.single] as String?;
    return [
      for (final e in jsonDecode(raw ?? '[]') as List)
        Map<String, dynamic>.from(e as Map),
    ];
  }
}

/// Fails or freezes the send with a given 0-based call index.
class _Api extends FakeRecallApi {
  _Api(super.queue, {super.server});

  int calls = 0;
  int? failAtCall;
  int? freezeAtCall;
  final frozen = Completer<void>();
  Future<void> Function(Map<String, dynamic> entry)? onSend;

  @override
  Future<int?> applyReview(Map<String, dynamic> e) async {
    final call = calls++;
    await onSend?.call(e);
    if (call == freezeAtCall) {
      frozen.complete();
      await Completer<void>().future;
    }
    if (call == failAtCall) throw StateError('invented network drop');
    return super.applyReview(e);
  }
}

final _now = DateTime(2026, 10, 13, 12);

/// Owner-scoped, catch-up-enabled offline fixture: a rating persists its
/// catch-up progress between its outbox append and its Undo slot.
class _CatchUpApi extends SanitizedRecallApi {
  _CatchUpApi()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [
            for (var id = 701; id <= 706; id++)
              ReviewCard(
                id: id,
                guid: 'invented-batch-$id',
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
              ),
          ],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.offline,
      );

  final sent = <Object?>[];
  final firstSent = Completer<void>();
  int? failAtCall;

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    final call = sent.length;
    sent.add(entry['client_id']);
    if (call == failAtCall) throw StateError('invented network drop');
    if (!firstSent.isCompleted) firstSent.complete();
    return 9000 + call;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  late SharedPreferencesStorePlatform previous;

  setUp(() {
    previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    native = _Native();
    SharedPreferencesStorePlatform.instance = native;
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });

  ReviewController build(RecallApi api, LocalReviewStore store) {
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// Rate [count] cards offline and return their event ids, oldest first.
  Future<List<Object>> offlineRatings(
    _Api api,
    LocalReviewStore store,
    ReviewController controller,
    int count,
  ) async {
    await controller.load();
    api.beforeQueue = () async => throw StateError('offline');
    await controller.refresh();
    expect(controller.state.offline, isTrue);
    for (var i = 0; i < count; i++) {
      controller.flip();
      await controller.rate(Rating.good);
    }
    api.beforeQueue = null;
    final rows = await native.outbox();
    expect(rows, hasLength(count));
    expect(rows.every((e) => e['delivery_attempted'] == false), isTrue);
    expect(controller.canUndo, isTrue);
    return [for (final e in rows) e['client_id'] as Object];
  }

  List<Object?> attempted(List<Map<String, dynamic>> rows) => [
    for (final e in rows) e['delivery_attempted'],
  ];

  List<Object?> loggedEvents(FakeRecallApi api) => [
    for (final row in api.server.reviewLog) row['client_event_id'],
  ];

  _Api api5() => _Api([for (var id = 1; id <= 5; id++) testCard(id: id)]);

  group('LocalReviewStore.markReviewsAttempted', () {
    test('marks listed queued reviews in one native write', () async {
      final store = LocalReviewStore();
      for (final id in ['invented-1', 'invented-2', 'invented-3']) {
        await store.enqueueReview({'client_id': id, 'card_id': 1});
      }
      native.resetCounts();
      final marked = await store.markReviewsAttempted([
        'invented-1',
        'invented-3',
        'invented-absent',
      ]);
      expect(marked, {'invented-1', 'invented-3'});
      expect(native.outboxWrites, 1);
      expect(attempted(await native.outbox()), [true, false, true]);
      // Marked reviews are no longer undoable; the unlisted one still is.
      expect((await store.removeEntry('invented-1')).removed, isFalse);
      expect((await store.removeEntry('invented-2')).removed, isTrue);
      expect((await LocalReviewStore().outbox()).map((e) => e['client_id']), [
        'invented-1',
        'invented-3',
      ]);
    });

    test('an empty or fully absent batch writes nothing', () async {
      final store = LocalReviewStore();
      await store.enqueueReview({'client_id': 'invented-1', 'card_id': 1});
      native.resetCounts();
      expect(await store.markReviewsAttempted(const []), isEmpty);
      expect(await store.markReviewsAttempted(['invented-absent']), isEmpty);
      expect(native.outboxWrites, 0);
      expect(attempted(await native.outbox()), [false]);
    });

    test('serializes with Undo so a removed review is never marked', () async {
      final store = LocalReviewStore();
      await store.enqueueReview({'client_id': 'invented-1', 'card_id': 1});
      await store.enqueueReview({'client_id': 'invented-2', 'card_id': 2});
      final removal = store.removeEntry('invented-2');
      final marking = store.markReviewsAttempted(['invented-1', 'invented-2']);
      expect((await removal).removed, isTrue);
      expect(await marking, {'invented-1'});
      final rows = await native.outbox();
      expect(rows.single['client_id'], 'invented-1');
      expect(rows.single['delivery_attempted'], isTrue);
    });

    test('marks every identical copy of one delivery identity', () async {
      final copy = {
        'client_id': 'invented-dup',
        'card_id': 1,
        'delivery_attempted': false,
      };
      await native.setValue('String', _outboxKey, jsonEncode([copy, copy]));
      final store = LocalReviewStore();
      expect(await store.markReviewsAttempted(['invented-dup']), {
        'invented-dup',
      });
      expect(attempted(await native.outbox()), [true, true]);
      expect((await store.removeEntry('invented-dup')).removed, isFalse);
      expect(await native.outbox(), hasLength(2));
    });

    test('a refused batch write throws and marks nothing', () async {
      final store = LocalReviewStore();
      await store.enqueueReview({'client_id': 'invented-1', 'card_id': 1});
      native.resetCounts();
      native.refuseAtWrite = 1;
      await expectLater(
        store.markReviewsAttempted(['invented-1']),
        throwsA(anything),
      );
      expect(attempted(await native.outbox()), [false]);
    });
  });

  group('ReviewController batched drain', () {
    test(
      'the Undo review stays undoable until its own send, as before',
      () async {
        final api = api5();
        final store = LocalReviewStore();
        final controller = build(api, store);
        final ids = await offlineRatings(api, store, controller, 4);
        final undoId = ids.last;
        final seen = <({Object? sending, List<Object?> marks, bool canUndo})>[];
        api.onSend = (entry) async => seen.add((
          sending: entry['client_id'],
          marks: attempted(await native.outbox()),
          canUndo: controller.canUndo,
        ));
        native.resetCounts();

        await controller.syncPending();

        expect(seen.map((s) => s.sending), ids);
        // First send is marked alone. Once it succeeds the two other reviews
        // are marked in one write; the Undo review is not.
        expect(seen[0].marks, [true, false, false, false]);
        expect(seen[1].marks, [true, true, true, false]);
        expect(seen[2].marks, [true, true, true, false]);
        for (final s in seen.take(3)) {
          expect(s.canUndo, isTrue, reason: 'before ${s.sending}');
        }
        // Exactly as before: its Undo closes immediately before its own send.
        expect(seen[3].marks, [true, true, true, true]);
        expect(seen[3].canUndo, isFalse);
        expect(seen[3].sending, undoId);

        expect(await native.outbox(), isEmpty);
        expect(loggedEvents(api), ids);
        // mark first + batch + mark Undo review + drain; per-review was 5.
        expect(native.outboxWrites, 4);
        await controller.undo();
        expect(controller.flagNotice, 'Synced reviews cannot be undone');
        expect(controller.state.index, 4);
        expect(api.undone, isEmpty);
      },
    );

    test('an offline flush marks only the first review, as before', () async {
      final api = api5();
      final store = LocalReviewStore();
      final controller = build(api, store);
      final ids = await offlineRatings(api, store, controller, 4);
      api.failAtCall = 0;
      native.resetCounts();

      await controller.syncPending();

      expect(native.outboxWrites, 1);
      final rows = await native.outbox();
      expect(rows.map((e) => e['client_id']), ids);
      expect(attempted(rows), [true, false, false, false]);
      expect(controller.canUndo, isTrue);
      await controller.undo();
      expect((await native.outbox()).map((e) => e['client_id']), ids.take(3));
    });

    test(
      'failure part-way keeps every review, Undo still works, replay is exact',
      () async {
        final api = api5();
        final store = LocalReviewStore();
        final controller = build(api, store);
        final ids = await offlineRatings(api, store, controller, 4);
        api.failAtCall = 1; // the second send drops after the batch mark

        await controller.syncPending();

        var rows = await native.outbox();
        expect(rows.map((e) => e['client_id']), ids.skip(1));
        // Failed send, batch-marked but unsent, and the untouched Undo review.
        expect(attempted(rows), [true, true, false]);
        expect(controller.state.pendingSync, 3);
        expect(loggedEvents(api), [ids[0]]);

        // Undo of the not-yet-sent review is pure local, exactly as before.
        expect(controller.canUndo, isTrue);
        await controller.undo();
        expect(controller.state.index, 3);
        expect(controller.state.pendingSync, 2);
        rows = await native.outbox();
        expect(rows.map((e) => e['client_id']), [ids[1], ids[2]]);

        api.failAtCall = null;
        await controller.syncPending();
        expect(await native.outbox(), isEmpty);
        expect(controller.state.pendingSync, 0);
        // Nothing lost or applied twice; the undone review never reached it.
        expect(loggedEvents(api), ids.take(3));
        expect(api.applied.map((e) => e['client_id']), ids.take(3));
        expect(api.undone, isEmpty);
      },
    );

    test(
      'a refused batch write stops the pass and keeps every review',
      () async {
        final api = api5();
        final store = LocalReviewStore();
        final controller = build(api, store);
        final ids = await offlineRatings(api, store, controller, 4);
        native.resetCounts();
        native.refuseAtWrite = 2; // first mark lands; the batch is refused

        await controller.syncPending();

        final rows = await native.outbox();
        expect(rows.map((e) => e['client_id']), ids.skip(1));
        expect(rows.last['delivery_attempted'], isFalse);
        expect(loggedEvents(api), [ids[0]]);
        expect(controller.canUndo, isTrue);

        await controller.syncPending();
        expect(await native.outbox(), isEmpty);
        expect(loggedEvents(api), ids);
      },
    );

    test(
      'crash after the batch mark, before its sends, replays each review once',
      () async {
        final server = FakeServer();
        final api = _Api([
          for (var id = 1; id <= 5; id++) testCard(id: id),
        ], server: server);
        final store = LocalReviewStore();
        final controller = build(api, store);
        final ids = await offlineRatings(api, store, controller, 4);
        api.freezeAtCall = 1; // process dies while sending the batch's first
        unawaited(controller.syncPending());
        await api.frozen.future.timeout(const Duration(seconds: 5));
        expect(api.calls, 2);
        expect(loggedEvents(api), [ids[0]]);

        // Restart: a fresh Store reads only what reached native storage.
        SharedPreferences.resetStatic();
        final rows = await native.outbox();
        expect(rows.map((e) => e['client_id']), ids);
        expect(attempted(rows), [true, true, true, false]);
        final restartedApi = _Api([
          for (var id = 1; id <= 5; id++) testCard(id: id),
        ], server: server);
        final restarted = build(restartedApi, LocalReviewStore());
        await restarted.load();
        expect(restarted.canUndo, isFalse);

        expect(await native.outbox(), isEmpty);
        expect(restarted.state.pendingSync, 0);
        // The delivered first review deduplicates; no review applies twice.
        expect(loggedEvents(api), ids);
        expect(restartedApi.applied.map((e) => e['client_id']), ids.skip(1));
        expect(restartedApi.calls, 4);
      },
    );

    test(
      'crash before the batch write is acknowledged loses nothing',
      () async {
        final server = FakeServer();
        final api = _Api([
          for (var id = 1; id <= 5; id++) testCard(id: id),
        ], server: server);
        final store = LocalReviewStore();
        final controller = build(api, store);
        final ids = await offlineRatings(api, store, controller, 4);
        native.resetCounts();
        native.crashAtWrite = 2; // the batch write never reaches native truth
        unawaited(controller.syncPending());
        await native.crashed.future.timeout(const Duration(seconds: 5));
        expect(api.calls, 1);

        SharedPreferences.resetStatic();
        native.crashAtWrite = null;
        final rows = await native.outbox();
        expect(rows.map((e) => e['client_id']), ids);
        expect(attempted(rows), [true, false, false, false]);
        final restartedApi = _Api([
          for (var id = 1; id <= 5; id++) testCard(id: id),
        ], server: server);
        final restarted = build(restartedApi, LocalReviewStore());
        await restarted.load();

        expect(await native.outbox(), isEmpty);
        expect(loggedEvents(api), ids);
        expect(restartedApi.applied.map((e) => e['client_id']), ids.skip(1));
      },
    );
  });

  test('the redo of an unconfirmed save stays undoable after a batch', () async {
    final api = api5();
    final store = LocalReviewStore();
    final controller = build(api, store);
    final ids = await offlineRatings(api, store, controller, 2);
    final cardId = controller.state.current!.id;
    controller.flip();
    native.throwAfterCommit = true;
    await expectLater(
      controller.rate(Rating.good),
      throwsA(isA<StudyActionUnconfirmedException>()),
    );
    native.failReads = false;
    final stored = await native.outbox();
    final unconfirmed = stored.last['client_id'];
    expect(stored.map((e) => e['client_id']), [...ids, unconfirmed]);

    api.failAtCall = 1; // first send lands, the batch is marked, then a drop
    await controller.syncPending();
    expect(api.calls, 2);
    expect((await native.outbox()).last['delivery_attempted'], isFalse);

    // The redo reuses the stored id and becomes the Undo slot; never sent.
    await controller.rate(Rating.good);
    expect(controller.state.current?.id, isNot(cardId));
    expect(controller.canUndo, isTrue);
    await controller.undo();
    expect(controller.state.current?.id, cardId);
    expect((await native.outbox()).map((e) => e['client_id']), [ids[1]]);
    expect(loggedEvents(api), [ids[0]]);
  });

  test(
    'a rating still saving its progress when the batch is marked stays undoable',
    () async {
      const wait = Duration(seconds: 5);
      final api = _CatchUpApi();
      addTearDown(api.disposeFixture);
      final store = LocalReviewStore();
      await store.activateOwner(api.currentUser!.id);
      await store.saveSnapshot(
        decks: api.dataset.decks,
        queue: api.dataset.cards,
        deckId: 1,
        globalDueCount: api.dataset.cards.length,
        globalDueUpdatedAt: _now,
      );
      await store.saveCatchUpState(
        const CatchUpLocalState(mode: CatchUpMode.active, dayKey: '2026-10-13'),
      );
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        haptics: const ReviewHaptics(),
        clock: () => _now,
      );
      addTearDown(controller.dispose);
      await controller.load(deckId: 1);
      expect(controller.state.offline, isTrue);
      expect(controller.state.catchUp.isActive, isTrue);
      for (var i = 0; i < 2; i++) {
        controller.flip();
        await controller.rate(Rating.good);
      }
      final earlier = [for (final e in await native.outbox()) e['client_id']];
      expect(earlier, hasLength(2));

      // Rating C appends, then holds on its progress write. A flush that read
      // C sends the oldest review and marks the rest in one batch meanwhile.
      final append = _Gate();
      final progress = _Gate();
      native.outboxGate = append;
      native.catchUpGate = progress;
      api.failAtCall = 1; // the second send drops
      controller.flip();
      final rating = controller.rate(Rating.good);
      await append.entered.future.timeout(wait);
      final sync = controller.syncPending();
      append.open();
      await progress.entered.future.timeout(wait);
      await api.firstSent.future.timeout(wait);
      await pumpEventQueue();
      progress.open();
      await Future.wait([rating, sync]).timeout(wait);

      final rows = await native.outbox();
      final ratedC = rows.last['client_id'];
      expect(rows.map((e) => e['client_id']), [earlier[1], ratedC]);
      expect(api.sent, [earlier[0], earlier[1]]);
      // C was never sent, so its Undo must work exactly as before.
      expect(rows.last['delivery_attempted'], isFalse);
      expect(controller.canUndo, isTrue);
      await controller.undo();
      expect((await native.outbox()).map((e) => e['client_id']), [earlier[1]]);
      expect(controller.state.reviewedThisSession, 2);
    },
  );

  group('drain cost', () {
    for (final count in [16, 64, 256]) {
      test('$count queued reviews drain in 3 writes and O(N) bytes', () async {
        final delegate = InMemorySharedPreferencesStore.empty();
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = delegate;
        final sample = await measureSyntheticOutboxCost(
          pendingCount: count,
          delegate: delegate,
        );
        // The largest list ever written: the seeded, never-attempted queue
        // ('false' is one byte longer than 'true').
        final fullList = utf8
            .encode(
              jsonEncode([
                for (var i = 0; i < count; i++) syntheticPendingReview(i),
              ]),
            )
            .length;
        expect(sample.transport.acceptedIds, hasLength(count));
        expect(sample.store.markedBeforeTransport, hasLength(count));
        // One single mark, one batch mark, one drain — independent of N.
        expect(sample.probe.acknowledgedWrites, 3);
        expect(sample.store.markCalls, 1);
        expect(sample.store.batchMarkCalls, 1);
        // Two full-list writes plus '[]': linear. A per-review rewrite would
        // have written about count full lists.
        expect(
          sample.probe.acknowledgedUtf8Bytes,
          lessThanOrEqualTo(2 * fullList + 2),
        );
        expect(
          sample.probe.acknowledgedUtf8Bytes,
          lessThan(count * fullList ~/ 4),
        );
      });
    }
  });
}

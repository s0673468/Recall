// Synthetic cards and local persistence only; no network services.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

enum _Pause { remediation, progressRead, progressWrite }

class _Gate {
  final entered = Completer<void>();
  final released = Completer<void>();

  Future<void> hold() async {
    entered.complete();
    await released.future;
  }

  void open() {
    if (!released.isCompleted) released.complete();
  }
}

class _Store extends LocalReviewStore {
  _Pause? pause;
  final gate = _Gate();

  Future<void> _hold(_Pause point) async {
    if (pause != point) return;
    pause = null;
    await gate.hold();
  }

  @override
  Future<List<LocalRemediationItem>> enqueueRemediation(
    Iterable<String> nodeIds, {
    DateTime? now,
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    await _hold(_Pause.remediation);
    return super.enqueueRemediation(
      nodeIds,
      now: now,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
  }

  @override
  Future<CatchUpLocalState> loadCatchUpState() async {
    await _hold(_Pause.progressRead);
    return super.loadCatchUpState();
  }

  @override
  Future<void> saveCatchUpState(
    CatchUpLocalState state, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    await _hold(_Pause.progressWrite);
    await super.saveCatchUpState(
      state,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final now = DateTime.utc(2031, 1, 2, 12);

  Future<(ReviewController, FakeRecallApi, _Store)> session({
    bool validation = false,
    bool active = true,
    bool offline = false,
  }) async {
    final api = FakeRecallApi([
      for (var id = 1; id <= 90; id++)
        testCard(
          id: id,
          state: 2,
          stability: 5,
          difficulty: 5,
          reps: 2,
          due: now.subtract(const Duration(days: 1)),
          lastReview: now.subtract(const Duration(days: 5)),
          tags: id == 1 ? 'node::synthetic-concept' : null,
          contentRevalidationPending: validation && id == 1,
        ),
    ]);
    final store = _Store();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    addTearDown(store.gate.open);
    await controller.load();
    expect(controller.state.catchUp.shouldOffer, isTrue);
    if (active) await controller.startCatchUp();
    if (offline) {
      api.beforeQueue = () async => throw StateError('Synthetic offline read');
      await controller.refresh();
      expect(controller.state.offline, isTrue);
    }
    expect(controller.state.current?.id, 1);
    return (controller, api, store);
  }

  for (final pause in _Pause.values) {
    test(
      'Review all during ${pause.name} cannot recache a committed due card',
      () async {
        final (controller, api, store) = await session();
        store.pause = pause;
        controller.flip();
        final rating = controller.rate(Rating.again);
        await store.gate.entered.future;
        expect((await store.outbox()).single['card_id'], 1);

        await controller.showAll();
        expect(
          controller.state.queue.map((card) => card.id),
          isNot(contains(1)),
        );
        store.gate.open();
        await rating;

        // This write used to cache the first card's pre-rating object again.
        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending();
        expect(await store.outbox(), isEmpty);
        expect(
          api.server.reviewLog.where((row) => row['card_id'] == 1),
          hasLength(1),
        );
        expect(
          (await store.loadSnapshot())!.queue.map((card) => card.id),
          isNot(contains(1)),
        );

        final offlineApi = FakeRecallApi([])
          ..beforeQueue = () async =>
              throw StateError('Synthetic offline read');
        final restarted = ReviewController(
          api: offlineApi,
          engine: FsrsEngine(),
          store: store,
          clock: () => now,
        );
        addTearDown(restarted.dispose);
        await restarted.load();
        expect(restarted.state.offline, isTrue);
        expect(
          restarted.state.queue.map((card) => card.id),
          isNot(contains(1)),
        );
      },
    );
  }

  for (final rating in [Rating.again, Rating.good]) {
    test(
      'choice during validation ${rating.name} preserves only an offline retry',
      () async {
        final (controller, api, store) = await session(
          validation: true,
          active: rating == Rating.good,
        );
        store.pause = rating == Rating.again
            ? _Pause.remediation
            : _Pause.progressRead;
        controller.flip();
        final pendingRating = controller.rate(rating);
        await store.gate.entered.future;
        if (rating == Rating.again) {
          await controller.startCatchUp();
        } else {
          await controller.showAll();
        }
        store.gate.open();
        await pendingRating;
        await controller.syncPending();
        expect(await store.outbox(), isEmpty);

        if (rating == Rating.again) await controller.showAll();
        expect(
          controller.state.queue.map((card) => card.id),
          isNot(contains(1)),
        );
        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending();
        final cachedIds = (await store.loadSnapshot())!.queue.map(
          (card) => card.id,
        );
        expect(
          cachedIds,
          rating == Rating.again ? contains(1) : isNot(contains(1)),
        );
        expect(
          api.server.reviewLog.where((row) => row['card_id'] == 1),
          hasLength(1),
        );
      },
    );
  }

  test(
    'Undo after optional progress restores an Again validation and its source',
    () async {
      final (controller, api, store) = await session(
        validation: true,
        offline: true,
      );
      final original = controller.state.current!;
      final before = controller.state.catchUp;
      store.pause = _Pause.progressWrite;
      controller.flip();
      final rating = controller.rate(Rating.again);
      await store.gate.entered.future;
      store.gate.open();
      await rating;
      expect(controller.canUndo, isTrue);

      await controller.undo();
      expect(controller.state.current, same(original));
      expect(controller.state.catchUp.completedToday, before.completedToday);
      expect(await store.outbox(), isEmpty);
      expect(api.applied, isEmpty);
      await controller.showAll();
      expect(controller.state.current, same(original));
      expect(
        controller.state.queue.where((card) => card.id == 1),
        hasLength(1),
      );
    },
  );
}

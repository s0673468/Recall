import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_test_harness.dart';

class _LikesApi extends FakeRecallApi {
  bool offlineLikes = false;
  Future<void> Function()? beforeLikedRead;
  _LikesApi() : super([testCard(id: 1), testCard(id: 2)]) {
    deckCounts = const {1: (due: 0, neu: 2)};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchLikedFlags() async {
    if (offlineLikes) throw StateError('synthetic offline');
    final rows = [
      for (final flag in flagged)
        if (flag['reason'] == 'like' &&
            !dismissedFlags.contains(flag['client_id']))
          Map<String, dynamic>.from(flag),
    ];
    await beforeLikedRead?.call();
    return rows;
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    if (flagged.any((f) => f['client_id'] == entry['client_id'])) return;
    await super.applyFlag(entry);
  }
}

class _HeldLikeStore extends LocalReviewStore {
  final gate = Completer<void>();
  int writes = 0;
  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) async {
    writes++;
    await gate.future;
    return super.enqueueFlag(entry);
  }
}

class _RefusingLikeStore extends LocalReviewStore {
  bool refuse = false;
  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) {
    if (refuse) throw LocalOutboxWriteException('synthetic-like-outbox');
    return super.enqueueFlag(entry);
  }
}

class _UnknownLikeStore extends LocalReviewStore {
  bool unknown = true;
  final ids = <Object?>[];

  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) async {
    ids.add(entry['client_id']);
    final count = await super.enqueueFlag(entry);
    if (unknown) throw StateError('synthetic lost native reply');
    return count;
  }

  @override
  Future<int?> settleUnknownFlag(Object clientId, {String? ownerScope}) async {
    if (unknown) throw StateError('synthetic unreadable native truth');
    return super.settleUnknownFlag(clientId, ownerScope: ownerScope);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ReviewController build(_LikesApi api, [LocalReviewStore? store]) {
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store ?? LocalReviewStore(),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test(
    'like records one flag without rating, hiding, skipping or changing deck counts',
    () async {
      final api = _LikesApi();
      final store = LocalReviewStore();
      final controller = build(api, store);
      await controller.load();
      final due = controller.state.globalDueCount;
      final neu = controller.state.newRemaining;
      await controller.toggleLike();
      await controller.syncPending();
      expect(controller.currentLiked, isTrue);
      expect(controller.flagNotice, 'Liked · keep this style');
      expect(api.flagged.single['reason'], 'like');
      expect(controller.state.current?.id, 1);
      expect(controller.state.showBack, isFalse);
      expect(controller.state.reviewedThisSession, 0);
      expect(controller.state.globalDueCount, due);
      expect(controller.state.newRemaining, neu);
      expect(api.applied, isEmpty);
      expect(await store.outbox(), isEmpty);
      expect(await store.hiddenCardIds(), isEmpty);
      await controller.refresh();
      expect(controller.state.queue.map((c) => c.id), [1, 2]);
      expect(api.lastExcludedCardIds, isEmpty);
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(api.applied.single['card_id'], 1);
      expect(controller.state.current?.id, 2);
      expect(controller.currentLiked, isFalse);
    },
  );

  test('a pending unlike never withdraws an independent dislike', () async {
    final api = _LikesApi()
      ..failApplyFlag = true
      ..failDismissFlag = true;
    final store = LocalReviewStore();
    await store.enqueueFlag({
      'card_id': 1,
      'reason': 'dislike',
      'client_id': 'synthetic-hide',
    });
    await store.enqueueFlag({
      'card_id': 1,
      'reason': 'like',
      'op': 'dismiss',
      'client_id': 'synthetic-like',
      'like_client_ids': ['synthetic-like'],
    });
    final controller = build(api, store);
    await controller.load();
    expect(controller.state.queue.map((c) => c.id), [2]);
    expect(controller.currentLiked, isFalse);
  });

  test(
    'unlike after sync is an offline durable dismiss and survives restart',
    () async {
      final api = _LikesApi();
      final store = LocalReviewStore();
      final controller = build(api, store);
      await controller.load();
      await controller.toggleLike();
      await controller.syncPending();
      final id = api.flagged.single['client_id'];
      api.failDismissFlag = true;
      api.offlineLikes = true;
      await controller.toggleLike();
      await controller.syncPending();
      expect(controller.currentLiked, isFalse);
      expect(controller.flagNotice, 'Like removed');
      expect((await store.flagOutbox()).single['op'], 'dismiss');
      final restarted = build(api, LocalReviewStore());
      await restarted.load();
      expect(restarted.currentLiked, isFalse);
      expect(restarted.state.current?.id, 1);
      api.failDismissFlag = false;
      api.offlineLikes = false;
      await restarted.syncPending();
      expect(api.dismissedFlags, [id]);
      expect(await store.flagOutbox(), isEmpty);
    },
  );

  test('offline like survives restart then syncs exactly once', () async {
    final api = _LikesApi()
      ..failApplyFlag = true
      ..offlineLikes = true;
    final store = LocalReviewStore();
    final first = build(api, store);
    await first.load();
    await first.toggleLike();
    final id = (await store.flagOutbox()).single['client_id'];
    final restarted = build(api, LocalReviewStore());
    await restarted.load();
    expect(restarted.currentLiked, isTrue);
    expect(restarted.state.queue.map((c) => c.id), [1, 2]);
    api.failApplyFlag = false;
    api.offlineLikes = false;
    await restarted.syncPending();
    await restarted.syncPending();
    expect(api.flagged.single['client_id'], id);
    expect(await store.flagOutbox(), isEmpty);
  });

  test('offline like then unlike never leaves an open like', () async {
    final api = _LikesApi()..failApplyFlag = true;
    final store = LocalReviewStore();
    final controller = build(api, store);
    await controller.load();
    await controller.toggleLike();
    final id = (await store.flagOutbox()).single['client_id'];
    await controller.toggleLike();
    api.failApplyFlag = false;
    await controller.syncPending();
    expect(api.flagged, isEmpty);
    expect(api.dismissedFlags, [id]);
    expect(controller.currentLiked, isFalse);
  });

  test('rapid taps while saving do not duplicate open likes', () async {
    final api = _LikesApi();
    final store = _HeldLikeStore();
    final controller = build(api, store);
    await controller.load();
    final first = controller.toggleLike();
    await controller.toggleLike();
    store.gate.complete();
    await first;
    await controller.syncPending();
    expect(store.writes, 1);
    expect(api.flagged, hasLength(1));
    expect(controller.currentLiked, isTrue);
  });

  test('unlike cannot overtake an in-flight like whose ACK is lost', () async {
    final api = _LikesApi();
    final started = Completer<void>();
    final release = Completer<void>();
    api.beforeApplyFlag = () {
      started.complete();
      return release.future;
    };
    api.commitThenThrowFlag = true;
    final controller = build(api);
    await controller.load();
    await controller.toggleLike();
    await started.future;
    await controller.toggleLike();
    expect(api.dismissedFlags, isEmpty);
    release.complete();
    await controller.syncPending();
    expect(api.flagged, hasLength(1));
    expect(api.dismissedFlags, [api.flagged.single['client_id']]);
    expect(controller.currentLiked, isFalse);
  });

  test(
    'server likes restore the mark and unlike withdraws every open identity',
    () async {
      final api = _LikesApi()
        ..flagged.addAll([
          {'card_id': 1, 'reason': 'like', 'client_id': 'synthetic-a'},
          {'card_id': 1, 'reason': 'like', 'client_id': 'synthetic-b'},
        ]);
      final controller = build(api);
      await controller.load();
      await settle();
      expect(controller.currentLiked, isTrue);
      await controller.toggleLike();
      await controller.syncPending();
      expect(api.dismissedFlags, ['synthetic-a', 'synthetic-b']);
      expect(controller.state.current?.id, 1);
    },
  );

  test('stale server read cannot overwrite a newly saved like', () async {
    final api = _LikesApi();
    final release = Completer<void>();
    api.beforeLikedRead = () => release.future;
    final controller = build(api);
    await controller.load();
    await controller.toggleLike();
    release.complete();
    await settle();
    expect(controller.currentLiked, isTrue);
  });

  test(
    'refused like and unlike preserve the previous mark and do not send',
    () async {
      final api = _LikesApi();
      final store = _RefusingLikeStore();
      final controller = build(api, store);
      await controller.load();
      store.refuse = true;
      await expectLater(
        controller.toggleLike(),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(controller.currentLiked, isFalse);
      expect(api.flagged, isEmpty);
      store.refuse = false;
      await controller.toggleLike();
      await controller.syncPending();
      store.refuse = true;
      await expectLater(
        controller.toggleLike(),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(controller.currentLiked, isTrue);
      expect(api.dismissedFlags, isEmpty);
    },
  );

  test('liked cache is owner scoped and cleared on sign out', () async {
    final store = LocalReviewStore();
    await store.activateOwner('synthetic-a');
    await store.replaceLikedFlags([
      {'card_id': 1, 'client_id': 'event', 'reason': 'like'},
    ]);
    await store.activateOwner('synthetic-b');
    expect(await store.likedFlags(), isEmpty);
    await store.activateOwner('synthetic-a');
    expect(await store.likedFlags(), hasLength(1));
    await store.clear();
    expect(await store.likedFlags(), isEmpty);
  });

  test(
    'retrying an unknown like commit retains its exact event identity',
    () async {
      final api = _LikesApi()..failApplyFlag = true;
      final store = _UnknownLikeStore();
      final controller = build(api, store);
      await controller.load();
      await expectLater(
        controller.toggleLike(),
        throwsA(isA<StudyActionUnconfirmedException>()),
      );
      expect(controller.currentLiked, isFalse);
      store.unknown = false;
      await controller.toggleLike();
      expect(store.ids.toSet(), hasLength(1));
      expect(await store.flagOutbox(), hasLength(1));
      api.failApplyFlag = false;
      await controller.syncPending();
      expect(api.flagged, hasLength(1));
      expect(controller.currentLiked, isTrue);
    },
  );

  for (final width in [320.0, 360.0]) {
    testWidgets('like toggle fits a $width Android viewport with large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _LikesApi();
      final controller = build(api);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 800),
              textScaler: const TextScaler.linear(1.5),
            ),
            child: Scaffold(
              body: StudyScreen(controller: controller, nativeIos: false),
            ),
          ),
        ),
      );
      final button = find.byKey(const Key('recall_flag_like'));
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
      expect(
        tester.getRect(find.byKey(const Key('recall_flag_delete'))).right,
        lessThanOrEqualTo(width),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(controller.state.current?.id, 1);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('like is disabled while a rating is being saved', (tester) async {
    final store = _HeldRatingStore();
    final controller = build(_LikesApi(), store);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudyScreen(controller: controller, nativeIos: false),
        ),
      ),
    );
    controller.flip();
    final rating = controller.rate(Rating.good);
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('recall_flag_like')))
          .onPressed,
      isNull,
    );
    await controller.toggleLike();
    expect(await store.flagOutbox(), isEmpty);
    store.gate.complete();
    await rating;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
  });
}

class _HeldRatingStore extends LocalReviewStore {
  final gate = Completer<void>();
  @override
  Future<int> enqueueReview(
    Map<String, dynamic> entry, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    await gate.future;
    return super.enqueueReview(
      entry,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReviewController undo', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    ReviewController build(
      FakeRecallApi api, {
      LocalReviewStore? store,
      DateTime Function()? clock,
    }) {
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store ?? LocalReviewStore(),
        clock: clock ?? DateTime.now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> offline(FakeRecallApi api, ReviewController controller) async {
      await controller.load(); // persist invented snapshot
      api.beforeQueue = () async => throw StateError('offline');
      await controller.refresh();
      expect(controller.state.offline, isTrue);
    }

    test('nothing is undoable before the first rating', () async {
      final api = FakeRecallApi([testCard(id: 1)]);
      final controller = build(api);
      await controller.load();
      await controller.undo();
      expect(controller.canUndo, isFalse);
      expect(api.undone, isEmpty);
    });

    test('never-attempted offline Undo is pure local, once', () async {
      final api = FakeRecallApi([
        testCard(id: 1),
        testCard(id: 2),
        testCard(id: 3),
      ]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await offline(api, controller);
      controller.flip();
      await controller.rate(Rating.good);
      controller.flip();
      await controller.rate(Rating.good);
      expect(api.applied, isEmpty);
      expect(controller.canUndo, isTrue);
      expect((await store.outbox()).last['delivery_attempted'], isFalse);
      await controller.undo();
      expect(controller.state.index, 1);
      expect(controller.state.showBack, isFalse);
      expect(controller.state.reviewedThisSession, 1);
      expect(controller.state.pendingSync, 1);
      expect((await store.outbox()).single['card_id'], 1);
      await controller.undo();
      expect(controller.state.index, 1);
      expect(controller.canUndo, isFalse);
      expect(api.undone, isEmpty);
      await controller.syncPending();
      expect(api.applied.single['card_id'], 1);
    });

    test(
      'successful delivery closes Undo without any remote restore',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final controller = build(api);
        await controller.load();
        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending();
        final logs = List<Map<String, dynamic>>.from(api.server.reviewLog);
        final reps = api.server.cards[1]!.reps;
        await controller.undo();
        await controller.undo();
        expect(controller.state.index, 1);
        expect(controller.state.reviewedThisSession, 1);
        expect(api.server.cards[1]!.reps, reps);
        expect(api.server.reviewLog, logs);
        expect(api.undone, isEmpty);
        expect(controller.canUndo, isFalse);
        expect(controller.flagNotice, isNull);
      },
    );

    for (final tied in [false, true]) {
      test(
        'a ${tied ? 'tied-time' : 'newer'} web review cannot be rewound',
        () async {
          final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
          final controller = build(api);
          await controller.load();
          controller.flip();
          await controller.rate(Rating.good);
          await controller.syncPending();
          final remote = api.server.cards[1]!;
          final at = DateTime.parse(
            api.applied.single['last_review'] as String,
          );
          remote.patch({
            'reps': remote.reps + 1,
            'lapses': remote.lapses + 1,
            'last_review': (tied ? at : at.add(const Duration(seconds: 1)))
                .toIso8601String(),
          });
          final tuple = (remote.reps, remote.lapses, remote.lastReview);
          await controller.undo();
          expect((remote.reps, remote.lapses, remote.lastReview), tuple);
          expect(api.undone, isEmpty);
          expect(controller.state.index, 1);
          expect(controller.canUndo, isFalse);
        },
      );
    }

    test(
      'Undo waits for an in-flight send and refuses after its acknowledgement',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        final gate = Completer<void>();
        api.beforeApplyReview = () => gate.future;
        await controller.load();
        controller.flip();
        await controller.rate(Rating.good);
        final undoing = controller.undo();
        await Future<void>.delayed(Duration.zero);
        expect((await store.outbox()).single['delivery_attempted'], isTrue);
        gate.complete();
        await undoing;
        await controller.syncPending();
        expect(controller.state.index, 1);
        expect(controller.canUndo, isFalse);
        expect(api.applied, hasLength(1));
        expect(api.undone, isEmpty);
      },
    );

    test(
      'lost acknowledgement retains marked event for exact-once replay',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)])
          ..commitThenThrowReview = true;
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();
        controller.flip();
        await controller.rate(Rating.good);
        await controller.undo(); // wait for the first, ambiguous attempt
        final pending = (await store.outbox()).single;
        final eventId = pending['client_id'];
        final reps = api.server.cards[1]!.reps;
        await controller.undo();
        expect(controller.state.index, 1);
        expect(controller.canUndo, isFalse);
        expect(
          (await LocalReviewStore().outbox()).single['delivery_attempted'],
          isTrue,
        );
        expect((await store.removeEntry(eventId as Object)).removed, isFalse);
        expect(api.server.reviewLog, hasLength(1));
        api.commitThenThrowReview = false;
        await controller.syncPending();
        expect(await store.outbox(), isEmpty);
        expect(api.server.cards[1]!.reps, reps);
        expect(api.server.reviewLog, hasLength(1));
        expect(api.server.reviewLog.single['client_event_id'], eventId);
        expect(api.undone, isEmpty);
      },
    );

    test(
      'failure before commit still expires Undo and preserves replay',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)])
          ..failApplyReview = true;
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();
        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending();
        await controller.undo();
        expect(controller.state.index, 1);
        expect(controller.canUndo, isFalse);
        expect((await store.outbox()).single['delivery_attempted'], isTrue);
        api.failApplyReview = false;
        await controller.syncPending();
        expect(api.server.reviewLog, hasLength(1));
        expect(api.undone, isEmpty);
      },
    );

    test(
      'account switch never removes the prior owner attempted event',
      () async {
        final store = LocalReviewStore();
        await store.activateOwner('invented-owner-a');
        final scope = store.activeOwnerScope;
        await store.enqueueReview({'client_id': 'invented-a', 'card_id': 1});
        await store.markReviewAttempted('invented-a', ownerScope: scope);
        await store.activateOwner('invented-owner-b');
        await store.enqueueReview({'client_id': 'invented-b', 'card_id': 2});
        expect((await store.removeEntry('invented-a')).removed, isFalse);
        expect((await store.outbox()).single['client_id'], 'invented-b');
        expect(
          (await store.outbox(ownerScope: scope)).single['delivery_attempted'],
          isTrue,
        );
        await store.activateOwner('invented-owner-a');
        expect((await store.removeEntry('invented-a')).removed, isFalse);
      },
    );

    test(
      'legacy persisted entries without an attempt marker cannot be removed',
      () async {
        SharedPreferences.setMockInitialValues({
          'recall_outbox_v1': jsonEncode([
            {'client_id': 'invented-legacy', 'card_id': 1},
          ]),
        });
        final store = LocalReviewStore();
        expect((await store.removeEntry('invented-legacy')).removed, isFalse);
        expect(await store.markReviewAttempted('invented-legacy'), isTrue);
        expect(
          (await LocalReviewStore().outbox()).single['delivery_attempted'],
          isTrue,
        );
      },
    );

    test(
      'attempt marker and removal serialize so a removed event is never sent',
      () async {
        final store = LocalReviewStore();
        await store.enqueueReview({'client_id': 'invented-1', 'card_id': 1});
        expect((await store.removeEntry('invented-1')).removed, isTrue);
        expect(await store.markReviewAttempted('invented-1'), isFalse);
        await store.enqueueReview({'client_id': 'invented-2', 'card_id': 2});
        expect(await store.markReviewAttempted('invented-2'), isTrue);
        expect((await store.removeEntry('invented-2')).removed, isFalse);
        expect(
          (await LocalReviewStore().outbox()).single['client_id'],
          'invented-2',
        );
      },
    );

    test('Undo cannot remove a different session persisted event', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await offline(api, controller);
      await store.enqueueReview({'card_id': 99, 'rating': 3, 'client_id': 1});
      controller.flip();
      await controller.rate(Rating.good);
      await controller.undo();
      expect((await store.outbox()).single['card_id'], 99);
      expect(controller.state.pendingSync, 1);
      expect(api.undone, isEmpty);
    });

    test(
      'queue reload drops unsent Undo while retaining the queued event',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await offline(api, controller);
        controller.flip();
        await controller.rate(Rating.good);
        api.failApplyReview = true;
        await controller.refresh();
        expect(controller.canUndo, isFalse);
        await controller.undo();
        expect(await store.outbox(), hasLength(1));
        expect(api.undone, isEmpty);
      },
    );

    test('pure local Undo restarts elapsed clock', () async {
      var now = DateTime.utc(2026, 7, 10, 12);
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store, clock: () => now);
      await offline(api, controller);
      now = now.add(const Duration(seconds: 5));
      controller.flip();
      await controller.rate(Rating.good);
      now = now.add(const Duration(seconds: 100));
      await controller.undo();
      now = now.add(const Duration(seconds: 3));
      controller.flip();
      await controller.rate(Rating.good);
      expect((await store.outbox()).single['elapsed_ms'], 3000);
    });
  });

  testWidgets('sync keeps the daily count and disables visible Undo quietly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
            child: StudyScreen(controller: controller),
          ),
        ),
      ),
    );
    controller.flip();
    await controller.rate(Rating.good);
    await controller.syncPending();
    await tester.pumpAndSettle();
    expect(find.text('Synced reviews cannot be undone'), findsNothing);
    expect(find.text('1 done'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('recall_study_undo')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Synced reviews cannot be undone'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('Undo UI', () {
    testWidgets('StudyScreen undo returns to the previous card front', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        testCard(id: 601, front: 'first question', back: 'first answer'),
        testCard(id: 602, front: 'second question', back: 'second answer'),
      ]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      api.beforeQueue = () async => throw StateError('offline');
      await controller.refresh();
      expect(controller.state.offline, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('recall_study_undo')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      expect(find.textContaining('second question'), findsOneWidget);
      expect(find.byTooltip('Undo'), findsOneWidget);

      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();

      expect(find.textContaining('first question'), findsOneWidget);
      expect(find.text('Show answer'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('recall_study_undo')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('the all-caught-up screen still offers undo', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        testCard(id: 603, front: 'only question', back: 'only answer'),
      ]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      api.beforeQueue = () async => throw StateError('offline');
      await controller.refresh();
      expect(controller.state.offline, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      // A never-attempted last rating remains recoverable on the done screen.
      expect(find.text('All caught up'), findsOneWidget);
      await tester.tap(find.text('Undo last rating'));
      await tester.pumpAndSettle();

      expect(find.textContaining('only question'), findsOneWidget);
      expect(find.text('Show answer'), findsOneWidget);
    });
  });
}

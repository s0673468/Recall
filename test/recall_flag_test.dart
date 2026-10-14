import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReviewController flag', () {
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
        clock: clock,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test(
      'flag enqueues reports with the card fields and unique client_ids',
      () async {
        final now = DateTime.utc(2026, 7, 10, 12);
        final api = FakeRecallApi([testCard(id: 7)]);
        api.failApplyFlag = true; // keep them queued so we can inspect
        final store = LocalReviewStore();
        final controller = build(api, store: store, clock: () => now);
        await controller.load();

        await controller.flag('wrong');
        await controller.flag('too_long'); // same card twice is allowed
        await controller.syncPending(); // flush attempted; fails; stays queued

        final flags = await store.flagOutbox();
        expect(flags.length, 2);
        expect(flags[0]['card_id'], 7);
        expect(flags[0]['guid'], 'g7');
        expect(flags[0]['reason'], 'wrong');
        expect(flags[1]['reason'], 'too_long');
        expect(flags[0]['device'], 'test');
        expect(flags[0]['flagged_at'], now.toIso8601String());
        // Unique even under a fixed clock — the counter disambiguates.
        expect(flags[0]['client_id'], isNot(flags[1]['client_id']));
        // The review flow is completely untouched.
        expect(controller.state.index, 0);
        expect(controller.state.showBack, isFalse);
        expect(controller.state.reviewedThisSession, 0);
        expect(api.applied, isEmpty);
      },
    );

    test('flag is a no-op for an unknown reason', () async {
      final api = FakeRecallApi([testCard(id: 1)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.flag('bogus');
      expect(await store.flagOutbox(), isEmpty);
    });

    test('flag is a no-op with no current card', () async {
      final api = FakeRecallApi(const []);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      expect(controller.state.current, isNull);
      await controller.flag('wrong');
      expect(await store.flagOutbox(), isEmpty);
    });

    test(
      'a failing flag flush never blocks the review flush in the same cycle',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        api.failApplyFlag = true; // note_flags does not exist yet
        // Hold review delivery until syncPending so both flushes run together.
        final gate = Completer<void>();
        api.beforeApplyReview = () => gate.future;
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();

        controller.flip();
        await controller.rate(Rating.good); // review queued (card 1)
        await controller.flag('wrong'); // flag queued (card 2, current)
        expect(controller.state.pendingSync, 1);

        gate.complete();
        // One combined foreground sync: the flag insert throws, the review
        // insert succeeds — fully isolated.
        await controller.syncPending();

        expect(api.applied.length, 1); // review delivered despite flag failure
        expect(api.applied.single['card_id'], 1);
        expect(controller.state.pendingSync, 0); // review outbox drained
        expect(api.flagged, isEmpty); // flag never delivered
        final left = await store.flagOutbox();
        expect(left.single['card_id'], 2); // still queued for retry
      },
    );

    test('one-tap dislike hides the card without rating it', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();

      await controller.hideCurrent('dislike');

      expect(controller.state.current?.id, 2);
      expect(controller.state.reviewedThisSession, 0);
      expect(api.applied, isEmpty);
      expect(controller.flagNotice, 'Hidden until Sunday review');
      expect(controller.canUndo, isTrue);
      await controller.syncPending();
      expect(api.flagged.single['reason'], 'dislike');
      expect(api.flagged.single['card_id'], 1);
    });

    test('hidden cards stay out of the queue after a reload', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('delete');
      await controller.syncPending();

      await controller.refresh();

      expect(controller.state.queue.map((c) => c.id), [2]);
    });

    test('an unsynced hide survives an offline reload', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      api.failApplyFlag = true; // flag stays queued locally
      api.failFetchHidden = true; // server truth unavailable
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('dislike');

      await controller.refresh();

      expect(controller.state.queue.map((c) => c.id), [2]);
    });

    test('undo brings back a hidden card and drops its queued flag', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      api.failApplyFlag = true;
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('dislike');

      await controller.undo();

      expect(controller.state.current?.id, 1);
      expect(controller.canUndo, isFalse);
      expect(await store.flagOutbox(), isEmpty);
      expect(await store.hiddenCardIds(), isEmpty);
    });

    test('undo dismisses a hide flag that already synced', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('delete');
      await controller.syncPending();
      final clientId = api.flagged.single['client_id'] as String;

      await controller.undo();

      expect(api.dismissedFlags, [clientId]);
      expect(controller.state.current?.id, 1);
      await controller.refresh();
      expect(controller.state.queue.map((c) => c.id), [1, 2]);
    });

    test(
      'an offline undo of a synced hide queues a durable withdrawal',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();
        await controller.hideCurrent('dislike');
        await controller.syncPending();
        final clientId = api.flagged.single['client_id'] as String;
        api.failDismissFlag = true;

        await controller.undo();

        expect(controller.state.current?.id, 1);
        expect(controller.canUndo, isFalse);
        expect((await store.flagOutbox()).single['op'], 'dismiss');
        // A reload while offline must not re-hide the withdrawn card.
        api.failDismissFlag = false;
        api.failFetchHidden = false;
        await controller.refresh();
        expect(api.dismissedFlags, [clientId]);
        expect(controller.state.queue.map((c) => c.id), [1, 2]);
      },
    );

    test('undo withdraws a flag whose delivery reply was lost', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      api.commitThenThrowFlag = true; // committed, but stays queued locally
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('delete');
      await controller.syncPending();
      expect(await store.flagOutbox(), hasLength(1));
      // Each retry re-delivers the same event id; the server dedupes it.
      final clientId = api.flagged.first['client_id'] as String;

      await controller.undo();

      expect(api.dismissedFlags, [clientId]);
      expect(await store.flagOutbox(), isEmpty);
      expect(controller.state.current?.id, 1);
    });

    test('hidden cards are excluded before the queue fetch limits', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('dislike');
      await controller.syncPending();

      await controller.refresh();

      expect(api.lastExcludedCardIds, {1});
    });

    test('keep going never brings back a hidden card', () async {
      final now = DateTime.now().toUtc();
      final api = FakeRecallApi([
        testCard(id: 1, state: 2, due: now.subtract(const Duration(hours: 1))),
      ]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('dislike');
      await controller.syncPending();
      expect(controller.state.isDone, isTrue);

      await controller.keepGoing();

      expect(api.lastAheadExcludedCardIds, {1});
      expect(controller.state.queue.map((c) => c.id), isNot(contains(1)));
      expect(controller.canUndo, isFalse);
    });

    test('a flag delivered during the hidden-card read stays hidden', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      api.failApplyFlag = true;
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.hideCurrent('dislike');
      // The server read sees the pre-insert state while the flag is
      // delivered and drained from the outbox in the meantime.
      api.onFetchHidden = () async {
        api
          ..onFetchHidden = null
          ..failApplyFlag = false;
        await controller.syncPending();
      };

      await controller.refresh();

      expect(api.flagged.single['card_id'], 1);
      expect(controller.state.queue.map((c) => c.id), [2]);
    });

    test('flags from another device are excluded before the limits', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)])
        ..flagged.add({
          'card_id': 1,
          'reason': 'dislike',
          'client_id': 'other-device',
        });
      final store = LocalReviewStore(); // no hidden cache on this device
      final controller = build(api, store: store);

      await controller.load();

      expect(api.queueFetches, 2); // refetched with the fresh hide set
      expect(api.lastExcludedCardIds, {1});
      expect(controller.state.queue.map((c) => c.id), [2]);
    });

    test(
      'a queued hide survives a lost cache write and an offline load',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)])
          ..failApplyFlag = true
          ..failFetchHidden = true;
        final store = LocalReviewStore();
        // The durable flag landed but the best-effort cache write did not.
        await store.enqueueFlag({
          'card_id': 1,
          'guid': 'g1',
          'reason': 'delete',
          'client_id': 'queued-hide',
        });
        final controller = build(api, store: store);

        await controller.load();

        expect(controller.state.queue.map((c) => c.id), [2]);
      },
    );

    test(
      'an undo finishing after a reload leaves the new queue alone',
      () async {
        final api = FakeRecallApi([
          testCard(id: 1),
          testCard(id: 2),
          testCard(id: 3),
        ]);
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();
        await controller.hideCurrent('dislike');
        await controller.syncPending();
        final gate = Completer<void>();
        api.beforeDismissFlag = () => gate.future;

        final undo = controller.undo();
        await Future<void>.delayed(Duration.zero);
        api.beforeDismissFlag = null;
        await controller.refresh(); // replaces the queue mid-withdrawal
        gate.complete();
        await undo;

        // The reloaded queue keeps its own position instead of jumping to the
        // old index; the withdrawn card returns on the next load.
        expect(controller.state.index, 0);
        expect(controller.state.isDone, isFalse);
        expect(controller.canUndo, isFalse);
        await controller.refresh();
        expect(controller.state.queue.map((c) => c.id), [1, 2, 3]);
      },
    );

    test(
      'hiding a due card lowers the global due count; undo restores it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime.utc(2026, 7, 13, 12);
        final api = FakeRecallApi([
          testCard(state: 2, due: now.subtract(const Duration(hours: 1))),
        ])..deckCounts = const {1: (due: 3, neu: 0)};
        final controller = build(api, clock: () => now);
        await controller.load();
        expect(controller.state.globalDueCount, 3);

        await controller.hideCurrent('dislike');
        expect(controller.state.globalDueCount, 2);

        await controller.undo();
        expect(controller.state.globalDueCount, 3);
      },
    );

    test('a refresh landing during a hide keeps the hidden card out', () async {
      final api = FakeRecallApi([
        testCard(id: 1),
        testCard(id: 2),
        testCard(id: 3),
      ]);
      api.failApplyFlag = true;
      final store = _GatedFlagStore();
      final controller = build(api, store: store);
      await controller.load();

      final hiding = controller.hideCurrent('dislike');
      await Future<void>.delayed(Duration.zero);
      await controller.refresh(); // lands while the flag write is pending
      store.enqueueGate.complete();
      await hiding;

      expect(controller.state.queue.map((c) => c.id), isNot(contains(1)));
      expect(controller.state.current?.id, isNot(1));
    });

    test('the forecast leaves out hidden cards', () async {
      final api = FakeRecallApi([testCard(id: 1)])
        ..flagged.add({'card_id': 7, 'reason': 'delete', 'client_id': 'x'});
      final service = StatsService(api);

      await service.loadAutomaticDueDates(refresh: true);

      expect(api.lastDueDateExcludedIds, {7});
    });

    test(
      'a rating after a hide makes the rating the undoable action',
      () async {
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();
        api.beforeQueue = () async => throw StateError('offline');
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        await controller.hideCurrent('dislike');
        controller.flip();
        await controller.rate(Rating.good);

        await controller.undo();

        // The rating is undone; the hidden card stays hidden.
        expect(controller.state.current?.id, 2);
        expect(controller.state.reviewedThisSession, 0);
      },
    );

    test(
      'sheet reasons do not hide and one-tap reasons need hideCurrent',
      () async {
        final api = FakeRecallApi([testCard(id: 1)]);
        api.failApplyFlag = true;
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();

        await controller.flag('dislike'); // ignored: hide reasons only hide
        expect(await store.flagOutbox(), isEmpty);
        await controller.flag('wrong');
        expect(controller.state.current?.id, 1);
        expect(controller.flagNotice, 'Flagged for the weekly review');
      },
    );

    test('a successful flag flush drains the flag outbox', () async {
      final api = FakeRecallApi([testCard(id: 1)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();

      await controller.flag('confusing');
      await controller.syncPending();

      expect(api.flagged.length, 1);
      expect(api.flagged.single['reason'], 'confusing');
      expect(api.flagged.single['card_id'], 1);
      expect(await store.flagOutbox(), isEmpty);
    });

    test(
      'an account switch stops the old flag outbox after its in-flight item',
      () async {
        final api = FakeRecallApi(const [])..user = testUser('account-a');
        final store = LocalReviewStore();
        await store.activateOwner('account-a');
        await store.enqueueFlag({'card_id': 1, 'client_id': 'flag-a-1'});
        await store.enqueueFlag({'card_id': 2, 'client_id': 'flag-a-2'});
        final firstDeliveryStarted = Completer<void>();
        final releaseFirstDelivery = Completer<void>();
        var deliveryCount = 0;
        api.beforeApplyFlag = () {
          deliveryCount++;
          if (deliveryCount == 1) {
            firstDeliveryStarted.complete();
            return releaseFirstDelivery.future;
          }
          return Future<void>.value();
        };
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        final sync = controller.syncPending();
        await firstDeliveryStarted.future;
        api.user = testUser('account-b');
        releaseFirstDelivery.complete();
        await sync;

        expect(api.flagged.map((entry) => entry['card_id']), [1]);
        final accountARemaining = await store.flagOutbox();
        expect(accountARemaining, hasLength(1));
        expect(accountARemaining.single['card_id'], 2);
      },
    );

    test('queued flags survive a store reload (simulated restart)', () async {
      final api1 = FakeRecallApi([testCard(id: 3)]);
      api1.failApplyFlag = true; // offline / table missing → stays queued
      final store1 = LocalReviewStore();
      final c1 = ReviewController(
        api: api1,
        engine: FsrsEngine(),
        store: store1,
      );
      await c1.load();
      await c1.flag('duplicate');
      await c1.syncPending(); // fails; flag persists in shared_preferences
      expect((await store1.flagOutbox()).length, 1);
      c1.dispose();

      // "Restart": brand-new store + controller over the same prefs, and the
      // table is up now.
      final api2 = FakeRecallApi([testCard(id: 3)]);
      final store2 = LocalReviewStore();
      final c2 = build(api2, store: store2);
      await c2.load();
      await c2.syncPending();

      expect(api2.flagged.length, 1);
      expect(api2.flagged.single['reason'], 'duplicate');
      expect(await store2.flagOutbox(), isEmpty);
    });
  });

  group('Flag UI', () {
    testWidgets('native iOS presents flag reasons as an action sheet', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: FakeRecallApi([testCard(id: 700)]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(
            body: StudyScreen(controller: controller, nativeIos: true),
          ),
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flag card'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Wrong'), findsOneWidget);
    }, tags: const ['apple-mobile']);

    testWidgets('flagging a card from the sheet enqueues and confirms', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final api = FakeRecallApi([
        testCard(id: 701, front: 'a question', back: 'an answer'),
      ]);
      api.failApplyFlag = true; // keep the flag queued so we can assert on it
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      // Open the sheet from the header flag icon; all four reasons present.
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flag card'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.text('Wrong'), findsOneWidget);
      expect(find.text('Confusing'), findsOneWidget);
      expect(find.text('Too long'), findsOneWidget);
      expect(find.text('Duplicate'), findsOneWidget);

      await tester.tap(find.text('Confusing'));
      await tester.pumpAndSettle();

      // Sheet dismissed, confirmation shown, flag queued, review untouched.
      expect(find.text('Confusing'), findsNothing);
      expect(find.text('Flagged for the weekly review'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      final flags = await store.flagOutbox();
      expect(flags.single['reason'], 'confusing');
      expect(flags.single['card_id'], 701);
      expect(controller.state.index, 0);
      expect(controller.state.showBack, isFalse);
      // The inline notice fades on its own.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('Flagged for the weekly review'), findsNothing);
    });

    testWidgets('the header thumbs-down hides the card in one tap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final api = FakeRecallApi([testCard(id: 711), testCard(id: 712)]);
      api.failApplyFlag = true;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );
      final dislikeBefore = tester.getCenter(
        find.byKey(const Key('recall_flag_dislike')),
      );
      await tester.tap(find.byKey(const Key('recall_flag_dislike')));
      await tester.pumpAndSettle();

      // Undo appearing must not shift the flag buttons under the finger.
      expect(
        tester.getCenter(find.byKey(const Key('recall_flag_dislike'))),
        dislikeBefore,
      );
      expect(controller.state.current?.id, 712);
      expect(find.text('Hidden until Sunday review'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect((await store.flagOutbox()).single['reason'], 'dislike');

      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(controller.state.current?.id, 711);
      expect(await store.flagOutbox(), isEmpty);

      await tester.tap(find.byKey(const Key('recall_flag_delete')));
      await tester.pumpAndSettle();
      expect(find.text('Marked for deletion'), findsOneWidget);
      expect((await store.flagOutbox()).single['reason'], 'delete');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('cancelling the flag sheet enqueues nothing', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: FakeRecallApi([testCard(id: 702)]),
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flag card'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.text('Wrong'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Wrong'), findsNothing); // sheet closed
      expect(await store.flagOutbox(), isEmpty);
    });

    testWidgets('the confirmation waits for the flag to be durably queued', (
      tester,
    ) async {
      // A PWA can be backgrounded/killed the instant the user sees the
      // confirmation — so the flag notice must never appear before the
      // SharedPreferences write has completed. Gate the store's enqueue and
      // assert the sheet stays up (no confirmation) until it lands.
      SharedPreferences.setMockInitialValues({});
      final store = _GatedFlagStore();
      final api = FakeRecallApi([testCard(id: 703)]);
      api.failApplyFlag = true; // keep the flag queued so we can assert on it
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flag card'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Wrong'));
      await tester.pump();
      await tester.pump();
      // Enqueue still in flight: no confirmation, sheet still open.
      expect(find.text('Flagged for the weekly review'), findsNothing);
      expect(find.text('Wrong'), findsOneWidget);

      store.enqueueGate.complete();
      await tester.pumpAndSettle();

      // Now — and only now — dismissed and confirmed, with the flag queued.
      expect(find.text('Wrong'), findsNothing);
      expect(find.text('Flagged for the weekly review'), findsOneWidget);
      expect((await store.flagOutbox()).single['card_id'], 703);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}

/// A [LocalReviewStore] whose [enqueueFlag] blocks on [enqueueGate] — lets the
/// widget test assert the flag-sheet confirmation waits for the durable write.
class _GatedFlagStore extends LocalReviewStore {
  final Completer<void> enqueueGate = Completer<void>();

  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) async {
    await enqueueGate.future;
    return super.enqueueFlag(entry);
  }
}

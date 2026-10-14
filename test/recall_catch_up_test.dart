import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReviewController catch-up', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('offers opt-in and opt-out without scheduling writes', () async {
      final api = FakeRecallApi(_catchUpQueue(82));
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.catchUp.shouldOffer, isTrue);
      expect(api.applied, isEmpty);
      final ordinaryIds = controller.state.queue
          .map((card) => card.id)
          .toList();

      await controller.startCatchUp();
      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.queue, hasLength(BacklogCatchUp.dailyCap));
      expect(api.applied, isEmpty);

      await controller.showAll();
      expect(controller.state.catchUp.isDismissed, isTrue);
      expect(controller.state.queue.map((card) => card.id), ordinaryIds);
      expect(api.applied, isEmpty);
    });

    test(
      'does not reintroduce a card reviewed before catch-up opt-in',
      () async {
        final queue = _catchUpQueue(82);
        final reviewed = queue.first;
        final api = FakeRecallApi(queue);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
          clock: () => DateTime.utc(2026, 8, 5, 12),
        );
        addTearDown(controller.dispose);

        await controller.load();
        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending();
        expect(await controller.store.outbox(), isEmpty);

        await controller.startCatchUp();

        expect(controller.state.catchUp.dueCount, 81);
        expect(
          controller.state.queue.any((card) => card.id == reviewed.id),
          isFalse,
        );
      },
    );

    test(
      'filters a pending review before catch-up eligibility and ordering',
      () async {
        final queue = _catchUpQueue(82);
        final api = FakeRecallApi(queue)..failApplyReview = true;
        final store = LocalReviewStore();
        await enqueuePendingReview(store: store, api: api, card: queue.first);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => DateTime.utc(2026, 8, 5, 12),
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(
          controller.state.queue.any((card) => card.id == queue.first.id),
          isFalse,
        );
        expect(controller.state.catchUp.shouldOffer, isTrue);
        expect(controller.state.catchUp.dueCount, 81);
      },
    );

    test('normal mode preserves due/new order below the threshold', () async {
      final due = testCard(
        id: 901,
        state: 2,
        stability: 5,
        due: DateTime.utc(2026, 8, 5, 11),
        lastReview: DateTime.utc(2026, 8, 1),
      );
      final fresh = testCard(id: 902, state: 0);
      final api = FakeRecallApi([due, fresh]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state.catchUp.shouldOffer, isFalse);
      expect(controller.state.queue.map((card) => card.id), [901, 902]);
      expect(api.applied, isEmpty);
    });

    test(
      'clears local catch-up mode when the fetched backlog is empty',
      () async {
        final api = FakeRecallApi(_catchUpQueue(82));
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
          clock: () => DateTime.utc(2026, 8, 5, 12),
        );
        addTearDown(controller.dispose);

        await controller.load();
        await controller.startCatchUp();
        expect(controller.state.catchUp.isActive, isTrue);

        api.queue.clear();
        await controller.refresh();

        expect(controller.state.catchUp.isNone, isTrue);
        expect(
          await controller.store.loadCatchUpState(),
          CatchUpLocalState.none,
        );
      },
    );

    test('undo restores the catch-up slot and local progress', () async {
      final api = FakeRecallApi(_catchUpQueue(82));
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);

      await controller.load();
      await controller.startCatchUp();
      api.beforeQueue = () async => throw StateError('offline');
      await controller.refresh();
      expect(controller.state.offline, isTrue);
      final before = controller.state.catchUp;
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.catchUp.completedToday, 1);

      await controller.undo();

      expect(controller.state.catchUp, before);
      expect(
        await controller.store.loadCatchUpState(),
        isNot(equals(CatchUpLocalState.none)),
      );
      expect(controller.state.current, isNotNull);
    });

    test(
      'undo restores progress when the final catch-up card clears the mode',
      () async {
        final now = DateTime.utc(2026, 8, 5, 12);
        final store = LocalReviewStore();
        await store.saveCatchUpState(
          CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: '2026-08-05',
            completedToday: 19,
          ),
        );
        final api = FakeRecallApi([
          testCard(
            id: 904,
            state: 2,
            stability: 5,
            difficulty: 5,
            due: now.subtract(const Duration(hours: 1)),
            lastReview: now.subtract(const Duration(days: 1)),
          ),
        ]);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.load();
        expect(controller.state.catchUp.isActive, isTrue);
        expect(controller.state.catchUp.completedToday, 19);
        api.beforeQueue = () async => throw StateError('offline');
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        controller.flip();
        await controller.rate(Rating.good);
        expect(controller.state.catchUp.isNone, isTrue);

        await controller.undo();

        final restored = await store.loadCatchUpState();
        expect(restored.mode, CatchUpMode.active);
        expect(restored.completedToday, 19);
        expect(controller.state.catchUp.isActive, isTrue);
        expect(controller.state.catchUp.completedToday, 19);
      },
    );

    test(
      'resets catch-up daily progress after midnight without reload',
      () async {
        var now = DateTime.utc(2026, 8, 5, 23, 30);
        final store = LocalReviewStore();
        final controller = ReviewController(
          api: FakeRecallApi(_catchUpQueue(82)),
          engine: FsrsEngine(),
          store: store,
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.load();
        await controller.startCatchUp();
        controller.flip();
        await controller.rate(Rating.good);
        expect((await store.loadCatchUpState()).completedToday, 1);

        now = DateTime.utc(2026, 8, 6, 0, 30);
        controller.flip();
        await controller.rate(Rating.good);

        final state = await store.loadCatchUpState();
        expect(state.dayKey, '2026-08-06');
        expect(state.completedToday, 1);
        expect(controller.state.catchUp.completedToday, 1);
      },
    );

    test('an older overlapping load cannot replace the newer queue', () async {
      final first = testCard(id: 901, deckId: 1, state: 2);
      final second = testCard(id: 902, deckId: 2, state: 2);
      final api = FakeRecallApi([first, second])..failApplyReview = true;
      final store = _GatedCatchUpStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);

      final firstLoad = controller.load();
      await store.catchUpLoadStarted.future;
      await enqueuePendingReview(store: store, api: api, card: first);

      await controller.selectDeck(2);
      expect(controller.state.deckFilter, 2);
      expect(controller.state.queue.map((card) => card.id), [902]);

      store.releaseCatchUpLoad.complete();
      await firstLoad;
      expect(controller.state.deckFilter, 2);
      expect(controller.state.queue.map((card) => card.id), [902]);
    });

    testWidgets('quiet Study keeps secondary actions in its menu', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        testCard(front: 'A clear prompt', back: 'An answer'),
      ]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      var settingsOpened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: StudyScreen(
              controller: controller,
              nativeIos: false,
              onOpenSettings: () => settingsOpened++,
            ),
          ),
        ),
      );
      expect(find.byTooltip('More options'), findsOneWidget);
      expect(find.byTooltip('Flag card'), findsNothing);
      expect(find.byTooltip('Settings'), findsNothing);
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Flag card'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(settingsOpened, 1);
      expect(api.applied, isEmpty);
      expect(controller.state.showBack, isFalse);
    });

    testWidgets(
      'quiet Study keeps settings reachable after the queue is complete',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final controller = ReviewController(
          api: FakeRecallApi([]),
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);
        await controller.load();
        var settingsOpened = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildRecallTheme(),
            home: Scaffold(
              body: StudyScreen(
                controller: controller,
                nativeIos: false,
                onOpenSettings: () => settingsOpened = true,
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        expect(find.text('Flag card'), findsNothing);
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(settingsOpened, isTrue);
      },
    );

    testWidgets('quiet Study session options preserve explicit catch-up', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: FakeRecallApi(_catchUpQueue(82)),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: StudyScreen(controller: controller, nativeIos: false),
          ),
        ),
      );
      expect(find.text('Large due backlog'), findsNothing);
      expect(find.text('Start catch-up'), findsNothing);
      await tester.tap(find.byTooltip('Session options'));
      await tester.pumpAndSettle();
      expect(find.text('Start catch-up'), findsOneWidget);
      expect(controller.state.catchUp.isActive, isFalse);
      await tester.tap(find.text('Start catch-up'));
      await tester.pumpAndSettle();
      expect(controller.state.catchUp.isActive, isTrue);
      expect(controller.state.queue, hasLength(20));
      expect(find.text('Show answer'), findsOneWidget);
    });

    testWidgets('study omits backlog prompts before the user opts in', (
      tester,
    ) async {
      final controller = ReviewController(
        api: FakeRecallApi(_catchUpQueue(82)),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      expect(controller.state.catchUp.shouldOffer, isTrue);
      expect(find.text('Large due backlog'), findsNothing);
      expect(find.text('Start catch-up'), findsNothing);
      expect(find.text('Show all'), findsNothing);
      expect(find.textContaining('20 cards/day'), findsNothing);
      expect(find.byKey(const Key('recall_study_card')), findsOneWidget);
      expect(find.text('Show answer'), findsOneWidget);
    });

    testWidgets('completed catch-up uses a simple session message', (
      tester,
    ) async {
      final store = LocalReviewStore();
      await store.saveCatchUpState(
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2026-08-05',
          completedToday: 20,
        ),
      );
      final controller = ReviewController(
        api: FakeRecallApi(_catchUpQueue(82)),
        engine: FsrsEngine(),
        store: store,
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.state.isDone, isTrue);
      expect(controller.state.catchUp.isActive, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      expect(find.text('Session complete'), findsOneWidget);
      expect(find.textContaining('catch-up'), findsNothing);
      expect(find.textContaining('daily'), findsNothing);
      expect(find.text('Reload'), findsOneWidget);
    });

    testWidgets('active catch-up does not add a progress line', (tester) async {
      await loadVisualFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ReviewController(
        api: FakeRecallApi(_catchUpQueue(82)),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => DateTime.utc(2026, 8, 5, 12),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.startCatchUp();
      for (var reviewed = 0; reviewed < 2; reviewed++) {
        controller.flip();
        await controller.rate(Rating.good);
      }

      expect(controller.state.catchUp.dueCount, 80);
      expect(controller.state.catchUp.completedToday, 2);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: RepaintBoundary(
            key: const Key('visual_benchmark_boundary'),
            child: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(
                  size: Size(390, 844),
                  padding: EdgeInsets.fromLTRB(0, 24, 0, 24),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(UiSpacing.sm),
                    child: StudyScreen(controller: controller),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Catch-up ·'), findsNothing);
      expect(find.textContaining('2/20 today'), findsNothing);
      expect(find.textContaining('about 5 days left'), findsNothing);
      await captureVisual(tester, 'catch-up-partial-day');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}

List<ReviewCard> _catchUpQueue(int count) {
  final now = DateTime.utc(2026, 8, 5, 12);
  return [
    for (var i = 0; i < count; i++)
      testCard(
        id: 1000 + i,
        state: 2,
        stability: (i + 1).toDouble(),
        difficulty: 5,
        due: now.subtract(Duration(hours: i + 1)),
        lastReview: now.subtract(Duration(days: i + 1)),
      ),
  ];
}

/// Holds the first catch-up state read so a newer deck load can win while an
/// older load is still building its presentation-only queue.
class _GatedCatchUpStore extends LocalReviewStore {
  final Completer<void> catchUpLoadStarted = Completer<void>();
  final Completer<void> releaseCatchUpLoad = Completer<void>();
  bool _gateNextCatchUpLoad = true;

  @override
  Future<CatchUpLocalState> loadCatchUpState() async {
    if (_gateNextCatchUpLoad) {
      _gateNextCatchUpLoad = false;
      catchUpLoadStarted.complete();
      await releaseCatchUpLoad.future;
    }
    return super.loadCatchUpState();
  }
}

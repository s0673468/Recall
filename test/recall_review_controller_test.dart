import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating, defaultParameters;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, AuthState, User;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReviewController', () {
    test(
      'automatic review excludes opt-in decks but direct deck study includes them',
      () async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime.utc(2026, 8, 22, 12);
        final api = FakeRecallApi(
          [
            testCard(id: 1, deckId: 1),
            testCard(
              id: 2,
              deckId: 2,
              state: 2,
              reps: 4,
              due: now.subtract(const Duration(hours: 1)),
              lastReview: now.subtract(const Duration(days: 7)),
            ),
          ],
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Portuguese'),
          ],
        )..deckCounts = const {1: (due: 4, neu: 3), 2: (due: 9, neu: 8)};
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(controller.state.queue.map((card) => card.id), [1]);
        expect(api.lastIncludedDeckIds, {1});
        expect(controller.state.globalDueCount, 4);

        await controller.selectDeck(2);

        expect(controller.state.queue.map((card) => card.id), [2]);
        expect(api.lastIncludedDeckIds, isNull);

        controller.flip();
        await controller.rate(Rating.good);
        expect(controller.state.globalDueCount, 4);
      },
    );

    test('material revalidation keeps FSRS history and prunes offline snapshot '
        'after success', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.utc(2026, 8, 12, 12);
      final revised = testCard(
        id: 91,
        state: 2,
        stability: 42.5,
        difficulty: 3.25,
        reps: 17,
        lapses: 2,
        due: DateTime.utc(2027, 1, 1, 12),
        lastReview: DateTime.utc(2026, 7, 1, 12),
        tags: 'topic content_revalidate::20260811T120000Z',
        contentRevalidationPending: true,
      );
      final api = FakeRecallApi([revised]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => now,
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.current?.id, 91);
      expect(controller.state.current?.stability, 42.5);
      expect(controller.state.current?.difficulty, 3.25);
      expect(controller.state.current?.reps, 17);
      expect(controller.state.current?.lapses, 2);
      expect(controller.state.globalDueCount, 0);

      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      // This is an ordinary FSRS review, not a reset: all seventeen historic
      // reps survive and this answer becomes rep eighteen.
      expect(api.server.cards[91]?.reps, 18);
      expect(api.server.cards[91]?.lapses, 2);

      // Serialize behind the unawaited snapshot convergence write.
      await store.outbox();
      expect((await store.loadSnapshot())?.queue, isEmpty);
    });

    test(
      'offline replay keeps a completed validation out of the cached queue',
      () async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime.utc(2026, 8, 12, 12);
        final revised = testCard(
          id: 92,
          state: 2,
          stability: 30,
          difficulty: 4,
          reps: 12,
          due: DateTime.utc(2027, 2, 1),
          lastReview: DateTime.utc(2026, 7, 1),
          tags: 'topic content_revalidate::20260811T120000Z',
          contentRevalidationPending: true,
        );
        final store = LocalReviewStore();
        final online = FakeRecallApi([revised])..failApplyReview = true;
        final first = ReviewController(
          api: online,
          engine: FsrsEngine(),
          store: store,
          clock: () => now,
        );
        addTearDown(first.dispose);
        await first.load();
        first.flip();
        await first.rate(Rating.good);
        await first.syncPending();
        expect(await store.outbox(), hasLength(1));

        final offline = FakeRecallApi([])
          ..failApplyReview = true
          ..beforeQueue = () async => throw StateError('offline');
        final restarted = ReviewController(
          api: offline,
          engine: FsrsEngine(),
          store: store,
          clock: () => now,
        );
        addTearDown(restarted.dispose);
        await restarted.load();

        expect(restarted.state.current, isNull);
        expect(restarted.state.offline, isTrue);
        expect(await store.outbox(), hasLength(1));
      },
    );

    test('auth failures never expose arbitrary exception text', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([])
        ..signInError = StateError('sensitive-marker-one sensitive-marker-two');
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      await controller.signIn(email: 'person@example.com', password: 'secret');

      expect(controller.state.error, 'Could not sign in. Try again.');
      expect(controller.state.error, isNot(contains('sensitive-marker')));
      expect(controller.state.authSubmitting, isFalse);
    });

    test('invalid credentials use the bounded helpful auth message', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([])
        ..signInError = const AuthException(
          'server wording can change',
          code: 'invalid_credentials',
        );
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      await controller.signIn(email: 'person@example.com', password: 'secret');

      expect(controller.state.error, 'Wrong email or password.');
    });

    test('a rapid double rating records the visible card only once', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard(), testCard(id: 2)])
        ..failApplyReview = true;
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.flip();

      await Future.wait([
        controller.rate(Rating.good),
        controller.rate(Rating.good),
      ]);

      expect(controller.state.reviewedThisSession, 1);
      expect(controller.state.current?.id, 2);
      expect(await store.outbox(), hasLength(1));
    });

    test(
      'a corrupt durable outbox becomes a recoverable startup error',
      () async {
        SharedPreferences.setMockInitialValues({
          'recall_outbox_v1': '{not valid json',
        });
        final controller = ReviewController(
          api: FakeRecallApi([testCard()]),
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);

        await controller.initialize();

        expect(controller.state.loading, isFalse);
        expect(controller.state.error, contains('pending study actions'));
      },
    );

    test(
      'offline sign-out preserves queued reviews and keeps the session',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([testCard()]);
        api.beforeApplyReview = () async => throw StateError('offline');
        final store = LocalReviewStore();
        var reminderCancelled = false;
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          afterSignOut: () async => reminderCancelled = true,
        );
        addTearDown(controller.dispose);
        await controller.load();
        controller.flip();
        await controller.rate(Rating.good);

        await expectLater(
          controller.signOut(),
          throwsA(isA<PendingSyncException>()),
        );

        expect(await store.outbox(), hasLength(1));
        expect(api.signedOut, isFalse);
        expect(reminderCancelled, isFalse);
      },
    );

    test(
      'successful sign-out cancels reminders only after writes drain',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([testCard()]);
        final events = <String>[];
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
          afterSignOut: () async {
            expect(api.signedOut, isTrue);
            events.add('reminder');
          },
        );
        addTearDown(controller.dispose);

        await controller.signOut();

        expect(api.signedOut, isTrue);
        expect(events, ['reminder']);
      },
    );

    test(
      'sign-out invalidates a load that is still fetching before it can save',
      () async {
        SharedPreferences.setMockInitialValues({});
        final gate = Completer<void>();
        final api = FakeRecallApi([testCard(id: 42)])
          ..beforeQueue = () => gate.future;
        final store = LocalReviewStore();
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        final loading = controller.load();
        while (api.queueFetches == 0) {
          await Future<void>.delayed(Duration.zero);
        }

        await controller.signOut();
        expect(await store.loadSnapshot(), isNull);

        gate.complete();
        await loading;
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(await store.loadSnapshot(), isNull);
      },
    );

    test(
      'sign-out blocks a snapshot save that passed the load token check',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _GatedSnapshotStore();
        final controller = ReviewController(
          api: FakeRecallApi([testCard(id: 42)]),
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        final loading = controller.load();
        await store.saveStarted.future;

        await controller.signOut();
        expect(await store.loadSnapshot(), isNull);

        store.releaseSave.complete();
        await store.saveFinished.future;
        await loading;

        expect(await store.loadSnapshot(), isNull);
      },
    );

    test(
      'load stores the global due count rather than the active queue',
      () async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime.utc(2026, 7, 13, 12);
        final api = FakeRecallApi(
          [testCard(state: 2, due: now.subtract(const Duration(hours: 1)))],
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Math'),
          ],
        )..deckCounts = const {1: (due: 3, neu: 2), 2: (due: 4, neu: 9)};
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
          clock: () => now,
        );
        addTearDown(controller.dispose);

        await controller.load(deckId: 1);

        expect(controller.state.queue, hasLength(1));
        expect(controller.state.globalDueCount, 7);
        expect(controller.state.globalDueUpdatedAt, now);
        expect(controller.state.reviewActivityKnown, isTrue);
        expect(controller.state.lastReviewedAt, isNull);

        api.beforeQueue = () async => throw StateError('offline');
        await controller.refresh();
        expect(controller.state.offline, isTrue);
        controller.flip();
        await controller.rate(Rating.good);
        expect(controller.state.globalDueCount, 6);
        expect(controller.state.lastReviewedAt, now);
        expect(controller.state.reviewActivityKnown, isTrue);

        await controller.undo();
        expect(controller.state.globalDueCount, 7);
        expect(controller.state.lastReviewedAt, isNull);
        expect(controller.state.reviewActivityKnown, isTrue);
      },
    );

    test('one review-log read serves catch-up and review activity', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final api = FakeRecallApi([testCard()])
        ..reviewLog = [
          ReviewLogEntry(at: now.subtract(const Duration(days: 5)), rating: 3),
        ];
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(api.reviewLogReads, [BacklogCatchUp.recentDays]);
      // The activity signal keeps the server's former 2-day window: an older
      // review is known activity but never counts as the latest review.
      expect(controller.state.reviewActivityKnown, isTrue);
      expect(controller.state.lastReviewedAt, isNull);

      final recent = now.subtract(const Duration(hours: 3));
      api.reviewLog = [
        ReviewLogEntry(at: now.subtract(const Duration(days: 5)), rating: 3),
        ReviewLogEntry(at: recent, rating: 3),
      ];
      await controller.refresh();
      expect(api.reviewLogReads, hasLength(2));
      expect(controller.state.lastReviewedAt, recent);

      api.failReviewLog = true;
      final failing = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(failing.dispose);
      await failing.load();
      expect(failing.state.queue, isNotEmpty);
      expect(failing.state.reviewActivityKnown, isFalse);
    });

    test(
      'keepGoing cards due later do not reduce the cloud due count',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([
          testCard(
            state: 2,
            stability: 10,
            difficulty: 5,
            reps: 3,
            due: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            lastReview: DateTime.now().toUtc().subtract(
              const Duration(days: 10),
            ),
          ),
        ])..deckCounts = const {1: (due: 7, neu: 0)};
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);

        await controller.load();
        controller.flip();
        await controller.rate(Rating.again);
        await controller.syncPending();
        expect(controller.state.globalDueCount, 6);

        await controller.keepGoing();
        expect(controller.state.current, isNotNull);
        expect(controller.state.current!.due, isNotNull);
        expect(
          controller.state.current!.due!.isAfter(DateTime.now().toUtc()),
          isTrue,
        );

        controller.flip();
        await controller.rate(Rating.good);
        expect(controller.state.globalDueCount, 6);
      },
    );

    test(
      'keepGoing loads a bonus batch and recaptures near-due learning cards',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([
          testCard(
            state: 2,
            stability: 10,
            difficulty: 5,
            reps: 3,
            due: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            lastReview: DateTime.now().toUtc().subtract(
              const Duration(days: 10),
            ),
          ),
        ]);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);

        await controller.load();
        controller.flip();
        // Again → relearning, due ~10 minutes ahead: exactly the card a
        // bonus batch must recapture so it can graduate the same day.
        await controller.rate(Rating.again);
        expect(controller.state.isDone, isTrue);

        await controller.keepGoing();

        expect(api.aheadFetches, 1);
        expect(controller.state.queue, hasLength(1));
        expect(controller.state.current?.state, 3);
        expect(controller.state.aheadExhausted, isFalse);
        // The session keeps counting and the old rating is no longer undoable.
        expect(controller.state.reviewedThisSession, 1);
        expect(controller.canUndo, isFalse);
      },
    );

    test(
      'keepGoing with nothing left marks exhausted until the next load',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([
          testCard(
            state: 2,
            stability: 10,
            difficulty: 5,
            reps: 3,
            due: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            lastReview: DateTime.now().toUtc().subtract(
              const Duration(days: 10),
            ),
          ),
        ]);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);

        await controller.load();
        controller.flip();
        // Good on a mature review card lands days out — beyond the horizon.
        await controller.rate(Rating.good);

        await controller.keepGoing();

        expect(controller.state.isDone, isTrue);
        expect(controller.state.aheadExhausted, isTrue);

        // A normal reload re-arms the button: the window has moved.
        await controller.refresh();
        expect(controller.state.aheadExhausted, isFalse);
      },
    );

    test('widget count failure never fails the study queue', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()])..failDeckCounts = true;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state.current?.id, 1);
      expect(controller.state.error, isNull);
      expect(controller.state.offline, isFalse);
      expect(controller.state.globalDueCount, isNull);
    });

    test('a cached-queue rating wins over an older count fetch', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final now = DateTime.utc(2026, 7, 13, 12);
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [
          testCard(state: 2, due: now.subtract(const Duration(hours: 1))),
        ],
        globalDueCount: 10,
        globalDueUpdatedAt: now.subtract(const Duration(minutes: 30)),
      );
      final queueStarted = Completer<void>();
      final releaseQueue = Completer<void>();
      final api =
          FakeRecallApi([
              testCard(state: 2, due: now.subtract(const Duration(hours: 1))),
            ])
            ..deckCounts = const {1: (due: 10, neu: 0)}
            ..beforeQueue = () async {
              queueStarted.complete();
              await releaseQueue.future;
            };
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => now,
      );
      addTearDown(controller.dispose);

      final loading = controller.load();
      await queueStarted.future;
      expect(controller.state.current?.id, 1);
      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.globalDueCount, 9);

      releaseQueue.complete();
      await loading;

      expect(controller.state.globalDueCount, 9);
      expect(
        controller.state.globalDueUpdatedAt,
        now.subtract(const Duration(minutes: 30)),
      );
    });

    test('foreground refresh runs only when idle and stale', () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime.utc(2026, 7, 13, 12);
      final api = FakeRecallApi(const [])
        ..user = User(
          id: 'user-1',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: now.toIso8601String(),
        );
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.queueFetches, 1);

      await controller.refreshIfIdle();
      expect(api.queueFetches, 1);

      now = now.add(const Duration(minutes: 16));
      await controller.refreshIfIdle();
      expect(api.queueFetches, 2);
    });

    test('foreground refresh never replaces an active card', () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime.utc(2026, 7, 13, 12);
      final api = FakeRecallApi([testCard()])
        ..user = User(
          id: 'user-1',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: now.toIso8601String(),
        );
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load();
      now = now.add(const Duration(hours: 1));

      await controller.refreshIfIdle();

      expect(api.queueFetches, 1);
      expect(controller.state.current?.id, 1);
    });

    test('successful study actions emit intentional native feedback', () async {
      SharedPreferences.setMockInitialValues({});
      final events = <String>[];
      final api = FakeRecallApi([testCard()]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        haptics: ReviewHaptics(
          onReveal: () => events.add('reveal'),
          onRating: () => events.add('rating'),
          onUndo: () => events.add('undo'),
          onCompletion: () => events.add('completion'),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();
      api.beforeQueue = () async => throw StateError('offline');
      await controller.refresh();

      controller.flip();
      expect(events, ['reveal']);

      await controller.rate(Rating.good);
      expect(events, ['reveal', 'rating', 'completion']);

      await controller.undo();
      expect(events, ['reveal', 'rating', 'completion', 'undo']);
    });

    test('blocked study actions do not emit native feedback', () async {
      SharedPreferences.setMockInitialValues({});
      final events = <String>[];
      final controller = ReviewController(
        api: FakeRecallApi(const []),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        haptics: ReviewHaptics(
          onReveal: () => events.add('reveal'),
          onRating: () => events.add('rating'),
          onUndo: () => events.add('undo'),
          onCompletion: () => events.add('completion'),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      await controller.undo();

      expect(events, isEmpty);
    });

    test('load applies seeded FSRS settings before study', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: FakeRecallApi(
          [testCard()],
          fsrsSettings: const FsrsSettings(
            parameters: desktopFsrsParameters,
            desiredRetention: 0.84,
          ),
        ),
        engine: engine,
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(engine.parameters, desktopFsrsParameters);
      expect(engine.desiredRetention, 0.84);
    });

    test('a superseded load cannot reapply signed-out FSRS settings', () async {
      SharedPreferences.setMockInitialValues({});
      final api = GatedFsrsRecallApi(
        [testCard()],
        fsrsSettings: const FsrsSettings(
          parameters: desktopFsrsParameters,
          desiredRetention: 0.84,
        ),
      );
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      addTearDown(api.authStates.close);

      final loading = controller.load();
      await api.fsrsStarted.future;

      api.authStates.add(const AuthState(AuthChangeEvent.signedOut, null));
      await Future<void>.delayed(Duration.zero);
      expect(engine.parameters, defaultParameters);

      api.releaseFsrs.complete();
      await loading;
      expect(engine.parameters, defaultParameters);
    });

    test('load resets stale FSRS settings when the row is absent', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = FsrsEngine(
        parameters: desktopFsrsParameters,
        desiredRetention: 0.84,
      );
      final controller = ReviewController(
        api: FakeRecallApi([testCard()]),
        engine: engine,
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(engine.parameters, defaultParameters);
      expect(engine.desiredRetention, 0.9);
    });

    test('cold start paints the snapshot before the network answers', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [testCard(id: 42, front: 'cached card')],
      );
      final api = FakeRecallApi([testCard(id: 1, front: 'fresh card')]);
      final gate = Completer<void>();
      api.beforeQueue = () => gate.future;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      final loading = controller.load();
      // The snapshot must be on screen while fetchQueue is still blocked.
      while (controller.state.queue.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.state.loading, isFalse);
      expect(controller.state.queue.single.id, 42);

      gate.complete();
      await loading;
      // The background fetch replaced the snapshot with the fresh queue.
      expect(controller.state.queue.single.id, 1);
      expect(controller.state.offline, isFalse);
    });

    test('a card hidden elsewhere leaves a retained snapshot queue', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [testCard(id: 1), testCard(id: 2)],
      );
      // Card 2 was hidden on another device; this device's cache lacks it.
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)])
        ..flagged.add({
          'card_id': 2,
          'reason': 'dislike',
          'client_id': 'other-device',
        });
      final gate = Completer<void>();
      api.beforeQueue = () => gate.future;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      final loading = controller.load();
      while (controller.state.queue.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.state.queue.map((c) => c.id), [1, 2]);
      controller.flip(); // studying the snapshot: load keeps this queue
      gate.complete();
      await loading;

      expect(controller.state.current?.id, 1);
      expect(controller.state.queue.map((c) => c.id), [1]);
    });

    test(
      'offline snapshot cannot leak an opt-in card into automatic review',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = LocalReviewStore();
        await store.saveSnapshot(
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Portuguese'),
          ],
          queue: [testCard(id: 1, deckId: 1), testCard(id: 2, deckId: 2)],
        );
        final api = FakeRecallApi(
          const [],
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Portuguese'),
          ],
        )..beforeQueue = () async => throw StateError('offline');
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(controller.state.queue.map((card) => card.id), [1]);
        expect(controller.state.offline, isTrue);
      },
    );

    test('offline restart never repaints cards with pending reviews', () async {
      SharedPreferences.setMockInitialValues({});
      final cards = [testCard(id: 1), testCard(id: 2)];
      final store = LocalReviewStore();
      final firstApi = FakeRecallApi(cards)
        ..beforeApplyReview = () async => throw StateError('offline');
      final first = ReviewController(
        api: firstApi,
        engine: FsrsEngine(),
        store: store,
      );

      await first.load();
      while (await store.loadSnapshot() == null) {
        await Future<void>.delayed(Duration.zero);
      }
      first.flip();
      await first.rate(Rating.good);
      first.flip();
      await first.rate(Rating.good);
      await first.syncPending();
      expect(await store.outbox(), hasLength(2));
      first.dispose();

      final fetchGate = Completer<void>();
      final restartApi = FakeRecallApi(cards);
      restartApi.beforeApplyReview = () async => throw StateError('offline');
      restartApi.beforeQueue = () async {
        await fetchGate.future;
        throw StateError('offline fetch');
      };
      final restarted = ReviewController(
        api: restartApi,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(restarted.dispose);

      final loading = restarted.load();
      while (restartApi.queueFetches == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(restarted.state.queue, isEmpty);
      expect(restarted.state.loading, isTrue);
      expect(restarted.state.pendingSync, 2);

      fetchGate.complete();
      await loading;
      expect(restarted.state.queue, isEmpty);
      expect(restarted.state.isDone, isTrue);
      expect(restarted.state.pendingSync, 2);
      expect(restarted.state.offline, isTrue);
    });

    test(
      'a failed partial flush filters the fetched queue by card id',
      () async {
        SharedPreferences.setMockInitialValues({});
        final cards = [testCard(id: 1), testCard(id: 2), testCard(id: 3)];
        final store = LocalReviewStore();
        final api = FakeRecallApi(cards);
        await enqueuePendingReview(store: store, api: api, card: cards[0]);
        await enqueuePendingReview(store: store, api: api, card: cards[1]);
        api.beforeApplyReview = () async => throw StateError('transient 5xx');
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(controller.state.queue.map((card) => card.id), [3]);
        expect(controller.state.pendingSync, 2);
        expect(await store.outbox(), hasLength(2));
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect((await store.loadSnapshot())!.queue.map((card) => card.id), [3]);
      },
    );

    test('a fully flushed outbox does not filter the fetched queue', () async {
      SharedPreferences.setMockInitialValues({});
      final cards = [testCard(id: 1), testCard(id: 2), testCard(id: 3)];
      final store = LocalReviewStore();
      final api = FakeRecallApi(cards);
      await enqueuePendingReview(store: store, api: api, card: cards[0]);
      await enqueuePendingReview(store: store, api: api, card: cards[1]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(await store.outbox(), isEmpty);
      expect(controller.state.pendingSync, 0);
      // The fake intentionally returns all three cards even after delivery.
      // Recomputing the outbox after the flush must therefore leave them all.
      expect(controller.state.queue.map((card) => card.id), [1, 2, 3]);
    });

    test(
      'a successful flush cannot revive a stale snapshot when fetch fails',
      () async {
        SharedPreferences.setMockInitialValues({});
        final cards = [testCard(id: 1), testCard(id: 2)];
        final store = LocalReviewStore();
        await store.saveSnapshot(
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          queue: cards,
        );
        final api = FakeRecallApi(cards);
        await enqueuePendingReview(store: store, api: api, card: cards[0]);
        await enqueuePendingReview(store: store, api: api, card: cards[1]);
        api.beforeQueue = () async => throw StateError('offline fetch');
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(await store.outbox(), isEmpty);
        expect(controller.state.pendingSync, 0);
        expect(controller.state.queue, isEmpty);
        expect(controller.state.offline, isTrue);
      },
    );

    test('background refresh never clobbers a session in progress', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [testCard(id: 42, front: 'cached card')],
      );
      final api = FakeRecallApi([testCard(id: 1, front: 'fresh card')]);
      final gate = Completer<void>();
      api.beforeQueue = () => gate.future;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      final loading = controller.load();
      while (controller.state.queue.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      // The user starts studying the snapshot mid-refresh.
      controller.flip();
      expect(controller.state.showBack, isTrue);

      gate.complete();
      await loading;
      // Queue and place preserved; only metadata refreshed.
      expect(controller.state.queue.single.id, 42);
      expect(controller.state.showBack, isTrue);
      expect(controller.state.decks.single.name, 'ML');
    });

    test(
      'rate advances to the next card without waiting on the sync',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
        final gate = Completer<void>();
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);
        await controller.load();

        api.beforeApplyReview = () => gate.future;
        controller.flip();
        await controller.rate(Rating.good);

        // Next card is up immediately; the review is queued, not yet delivered.
        expect(controller.state.index, 1);
        expect(controller.state.pendingSync, 1);
        expect(api.applied, isEmpty);

        gate.complete();
        await controller.syncPending();
        expect(api.applied.length, 1);
        expect(controller.state.pendingSync, 0);
      },
    );

    test('a deck switch supersedes a still-in-flight load', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        testCard(id: 1, deckId: 1),
        testCard(id: 2, deckId: 2),
      ]);
      // Gate only the FIRST fetch (the cold all-decks load); the deck-switch
      // fetch goes straight through and finishes first.
      final gate = Completer<void>();
      var fetches = 0;
      api.beforeQueue = () {
        fetches++;
        return fetches == 1 ? gate.future : Future.value();
      };
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      final coldLoad = controller.load(); // blocked on the gate
      while (fetches == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.selectDeck(2);
      expect(controller.state.queue.single.id, 2);

      // The superseded cold load must not clobber the deck-2 queue.
      gate.complete();
      await coldLoad;
      expect(controller.state.deckFilter, 2);
      expect(controller.state.queue.single.id, 2);
    });

    test(
      'a rating enqueued mid-flush is delivered by the follow-up pass',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = FakeRecallApi([
          testCard(id: 1),
          testCard(id: 2),
          testCard(id: 3),
        ]);
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);
        await controller.load();

        // Hold the first flush open on its first delivery, rate a second card
        // while it is stuck, then release it.
        final gate = Completer<void>();
        var deliveries = 0;
        api.beforeApplyReview = () {
          deliveries++;
          return deliveries == 1 ? gate.future : Future.value();
        };

        controller.flip();
        await controller.rate(Rating.good); // flush starts, blocks on gate
        controller.flip();
        await controller.rate(Rating.good); // enqueued while flush is stuck
        expect(controller.state.pendingSync, 2);

        gate.complete();
        await controller.syncPending();
        expect(api.applied.length, 2);
        expect(controller.state.pendingSync, 0);
        expect(controller.state.index, 2);
      },
    );

    test(
      'an account switch stops the old review outbox after its in-flight item',
      () async {
        SharedPreferences.setMockInitialValues({});
        final cards = [testCard(id: 1), testCard(id: 2)];
        final api = FakeRecallApi(cards)..user = testUser('account-a');
        final store = LocalReviewStore();
        await store.activateOwner('account-a');
        await enqueuePendingReview(store: store, api: api, card: cards[0]);
        await enqueuePendingReview(store: store, api: api, card: cards[1]);
        final firstDeliveryStarted = Completer<void>();
        final releaseFirstDelivery = Completer<void>();
        var deliveryCount = 0;
        api.beforeApplyReview = () {
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
        // Supabase has replaced its session, but the serialized local cleanup
        // has not yet released account A's namespace.
        api.user = testUser('account-b');
        releaseFirstDelivery.complete();
        await sync;

        expect(api.applied.map((entry) => entry['card_id']), [1]);
        final accountARemaining = await store.outbox();
        expect(accountARemaining, hasLength(1));
        expect(accountARemaining.single['card_id'], 2);
      },
    );
  });

  group('ReviewController elapsed time', () {
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime.utc(2026, 7, 10, 12);
    });

    ReviewController build(FakeRecallApi api, {LocalReviewStore? store}) {
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store ?? LocalReviewStore(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test(
      'rate stamps elapsed_ms from card display to the rating tap',
      () async {
        final api = FakeRecallApi([testCard(id: 1)]);
        final controller = build(api);
        await controller.load();

        now = now.add(const Duration(seconds: 3));
        controller.flip(); // revealing the answer must NOT reset the clock
        now = now.add(const Duration(seconds: 2));
        await controller.rate(Rating.good);
        await controller.syncPending();

        expect(api.applied.single['elapsed_ms'], 5000);
      },
    );

    test('elapsed_ms is capped at five minutes and floored at zero', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final controller = build(api);
      await controller.load();

      now = now.add(const Duration(minutes: 12)); // walked away mid-card
      controller.flip();
      await controller.rate(Rating.good);

      now = now.subtract(const Duration(seconds: 30)); // clock skew backwards
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();

      expect(api.applied[0]['elapsed_ms'], 300000);
      expect(api.applied[1]['elapsed_ms'], 0);
    });

    test('the clock restarts on every advanced-to card', () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final controller = build(api);
      await controller.load();

      now = now.add(const Duration(seconds: 5));
      controller.flip();
      await controller.rate(Rating.good);

      now = now.add(const Duration(seconds: 7));
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();

      expect(api.applied[0]['elapsed_ms'], 5000);
      expect(api.applied[1]['elapsed_ms'], 7000);
    });

    test(
      'an offline review carries the elapsed measured at review time',
      () async {
        final api = FakeRecallApi([testCard(id: 1)]);
        api.beforeApplyReview = () async => throw StateError('offline');
        final store = LocalReviewStore();
        final controller = build(api, store: store);
        await controller.load();

        now = now.add(const Duration(seconds: 4));
        controller.flip();
        await controller.rate(Rating.good);
        await controller.syncPending(); // fails; the review stays queued
        expect(api.applied, isEmpty);
        expect(controller.state.pendingSync, 1);
        expect((await store.outbox()).single['elapsed_ms'], 4000);

        // Flushing hours later must deliver the value measured at review time.
        now = now.add(const Duration(hours: 6));
        api.beforeApplyReview = null;
        await controller.syncPending();
        expect(api.applied.single['elapsed_ms'], 4000);
      },
    );
  });
}

/// Holds the first snapshot write after the controller has passed its load
/// token check, so sign-out can clear the store in the middle of that write.
class _GatedSnapshotStore extends LocalReviewStore {
  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> releaseSave = Completer<void>();
  final Completer<void> saveFinished = Completer<void>();

  @override
  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
    int? deckId,
    int? globalDueCount,
    DateTime? globalDueUpdatedAt,
    bool Function()? canWrite,
  }) async {
    saveStarted.complete();
    await releaseSave.future;
    try {
      await super.saveSnapshot(
        decks: decks,
        queue: queue,
        deckId: deckId,
        globalDueCount: globalDueCount,
        globalDueUpdatedAt: globalDueUpdatedAt,
        canWrite: canWrite,
      );
    } finally {
      saveFinished.complete();
    }
  }
}

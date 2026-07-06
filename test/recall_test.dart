import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating, defaultParameters;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthState, SupabaseClient, User;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/rating_bar.dart';

const _desktopFsrsParameters = [
  0.98086613,
  2.09384704,
  13.26146507,
  13.43933392,
  6.41675615,
  0.78818476,
  2.95193529,
  0.03727497,
  1.8791039,
  0.18768801,
  0.80702776,
  1.6284579,
  0.05166227,
  0.50534296,
  1.72878981,
  0.49406245,
  2.15494156,
  0.6520682,
  0.2181288,
  0.05643269,
  0.15054572,
];

ReviewCard _card({
  int id = 1,
  int deckId = 1,
  double? stability,
  double? difficulty,
  int state = 0,
  int reps = 0,
  int lapses = 0,
  DateTime? due,
  DateTime? lastReview,
  bool hasLatex = false,
  String front = 'front',
  String back = 'back',
}) => ReviewCard(
  id: id,
  guid: 'g$id',
  deckId: deckId,
  front: front,
  back: back,
  hasLatex: hasLatex,
  stability: stability,
  difficulty: difficulty,
  due: due,
  state: state,
  reps: reps,
  lapses: lapses,
  lastReview: lastReview,
);

class _FakeRecallApi implements RecallApi {
  final List<ReviewCard> queue;
  final FsrsSettings? fsrsSettings;

  /// Awaited inside fetchQueue — lets tests hold the network fetch open
  /// while asserting on the snapshot-hydrated state.
  Future<void> Function()? beforeQueue;

  /// Awaited inside applyReview — lets tests block the outbox flush.
  Future<void> Function()? beforeApplyReview;

  /// Every entry applyReview delivered, in order.
  final List<Map<String, dynamic>> applied = [];

  _FakeRecallApi(this.queue, {this.fsrsSettings});

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  User? get currentUser => null;

  @override
  String get device => 'test';

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();

  @override
  Future<List<DeckRow>> fetchDecks() async => const [
    DeckRow(deckId: 1, name: 'Portuguese'),
  ];

  @override
  Future<List<ReviewCard>> fetchQueue({int? deckId, int newLimit = 20}) async {
    await beforeQueue?.call();
    if (deckId == null) return queue;
    return [
      for (final c in queue)
        if (c.deckId == deckId) c,
    ];
  }

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async => fsrsSettings;

  @override
  Future<void> applyReview(Map<String, dynamic> e) async {
    await beforeApplyReview?.call();
    applied.add(e);
  }

  @override
  Map<String, dynamic> reviewEntry(ReviewCard card, ReviewOutcome o) => {
    'card_id': card.id,
  };

  @override
  Future<List<({DateTime at, int rating})>> fetchRecentReviews({
    int days = 30,
  }) async => const [];

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async => const {};

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  group('FsrsEngine', () {
    final engine = FsrsEngine();
    final now = DateTime.utc(2026, 6, 26, 12);

    test('a new card schedules forward and counts the rep', () {
      final out = engine.review(_card(state: 0), Rating.good, now: now);
      expect(out.reps, 1);
      expect(out.lapses, 0);
      expect(out.due.isAfter(now), isTrue);
      expect(out.state, isIn(const [1, 2])); // learning or review, never new
      expect(out.stability, greaterThan(0));
    });

    test('Again on a review card records a lapse', () {
      final out = engine.review(
        _card(
          id: 2,
          state: 2,
          stability: 10,
          difficulty: 5,
          reps: 3,
          due: DateTime.utc(2026, 6, 20),
          lastReview: DateTime.utc(2026, 6, 10),
        ),
        Rating.again,
        now: now,
      );
      expect(out.reps, 4);
      expect(out.lapses, 1);
    });

    test('preview gives four ratings with non-decreasing intervals', () {
      final p = engine.preview(_card(state: 0), now: now);
      expect(p.keys.toSet(), Rating.values.toSet());
      expect(!p[Rating.again]!.isAfter(p[Rating.good]!), isTrue);
      expect(!p[Rating.good]!.isAfter(p[Rating.easy]!), isTrue);
    });

    test('can be configured from seeded FSRS settings', () {
      final engine = FsrsEngine();
      engine.configure(
        const FsrsSettings(
          parameters: _desktopFsrsParameters,
          desiredRetention: 0.82,
        ),
      );
      expect(engine.parameters, _desktopFsrsParameters);
      expect(engine.desiredRetention, 0.82);
    });

    test('can reset back to package defaults', () {
      final engine = FsrsEngine(
        parameters: _desktopFsrsParameters,
        desiredRetention: 0.82,
      );
      engine.resetToDefaults();
      expect(engine.parameters, defaultParameters);
      expect(engine.desiredRetention, 0.9);
    });
  });

  group('FsrsSettings', () {
    test('parses seeded parameters and desired retention', () {
      final parsed = FsrsSettings.tryParse({
        'parameters': List<double>.filled(21, 1),
        'desired_retention': 0.86,
      });
      expect(parsed, isNotNull);
      expect(parsed!.parameters, hasLength(21));
      expect(parsed.desiredRetention, 0.86);
    });

    test('accepts legacy weights key and rejects wrong vector length', () {
      final parsed = FsrsSettings.tryParse({
        'weights': List<int>.filled(21, 2),
      });
      expect(parsed?.parameters.first, 2.0);
      expect(
        FsrsSettings.tryParse({
          'weights': [1, 2, 3],
        }),
        isNull,
      );
    });
  });

  group('ReviewController', () {
    test('load applies seeded FSRS settings before study', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: _FakeRecallApi(
          [_card()],
          fsrsSettings: const FsrsSettings(
            parameters: _desktopFsrsParameters,
            desiredRetention: 0.84,
          ),
        ),
        engine: engine,
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(engine.parameters, _desktopFsrsParameters);
      expect(engine.desiredRetention, 0.84);
    });

    test('load resets stale FSRS settings when the row is absent', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = FsrsEngine(
        parameters: _desktopFsrsParameters,
        desiredRetention: 0.84,
      );
      final controller = ReviewController(
        api: _FakeRecallApi([_card()]),
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
        decks: const [DeckRow(deckId: 1, name: 'Portuguese')],
        queue: [_card(id: 42, front: 'cached card')],
      );
      final api = _FakeRecallApi([_card(id: 1, front: 'fresh card')]);
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

    test('background refresh never clobbers a session in progress', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'Portuguese')],
        queue: [_card(id: 42, front: 'cached card')],
      );
      final api = _FakeRecallApi([_card(id: 1, front: 'fresh card')]);
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
      expect(controller.state.decks.single.name, 'Portuguese');
    });

    test('rate advances to the next card without waiting on the sync', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
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
    });

    test('a deck switch supersedes a still-in-flight load', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([
        _card(id: 1, deckId: 1),
        _card(id: 2, deckId: 2),
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

    test('a rating enqueued mid-flush is delivered by the follow-up pass',
        () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2), _card(id: 3)]);
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
    });
  });

  group('UI widgets', () {
    testWidgets('RatingBar shows all four ratings and reports taps', (
      tester,
    ) async {
      Rating? tapped;
      final now = DateTime.now().toUtc();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RatingBar(
              preview: {
                for (final r in Rating.values)
                  r: now.add(Duration(days: r.value)),
              },
              onRate: (r) => tapped = r,
            ),
          ),
        ),
      );
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);

      await tester.tap(find.text('Easy'));
      expect(tapped, Rating.easy);
    });

    testWidgets('CardFace renders plain text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: 'What is backprop?',
              hasLatex: false,
              style: TextStyle(),
            ),
          ),
        ),
      );
      expect(find.textContaining('backprop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CardFace renders inline LaTeX without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: r'Embedding: vocab \(=5000\), dim \([32,10]\)',
              hasLatex: true,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('CardFace keeps punctuation with preceding inline LaTeX', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CardFace(
              html: r'Write the formula in terms of \(Q, K, V\).',
              hasLatex: true,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pump();

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), contains('\u2060.'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('CardFace wraps long LaTeX formulas within the card width', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: CardFace(
                  html:
                      r'Attention \(Q, K, V\) = \( \operatorname{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right)V \)',
                  hasLatex: true,
                  style: TextStyle(fontSize: 24),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      for (final element in find.byType(Math).evaluate()) {
        final width = tester.getSize(find.byWidget(element.widget)).width;
        expect(width, lessThanOrEqualTo(280));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('StudyScreen reveals answers only from the button', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: _FakeRecallApi([
          _card(front: 'Complete: nos __ felizes.', back: 'eramos'),
        ]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      expect(find.text('Tap to reveal'), findsNothing);
      expect(find.text('Show answer'), findsOneWidget);
      expect(find.textContaining('eramos'), findsNothing);

      await tester.tap(find.byType(SingleChildScrollView));
      await tester.pump();
      expect(find.textContaining('eramos'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      expect(find.textContaining('eramos'), findsOneWidget);
    });
  });

  group('Offline store', () {
    test('snapshot round-trips decks + queue', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [
          _card(
            id: 7,
            state: 2,
            stability: 5,
            difficulty: 3,
            due: DateTime.utc(2026, 7, 1),
            hasLatex: true,
            front: r'vocab \(=5000\)',
          ),
        ],
      );
      final snap = await store.loadSnapshot();
      expect(snap, isNotNull);
      expect(snap!.decks.single.name, 'ML');
      expect(snap.queue.single.id, 7);
      expect(snap.queue.single.hasLatex, isTrue);
      expect(snap.queue.single.stability, 5);
    });

    test('outbox enqueues and drains', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      expect(await store.enqueueReview({'card_id': 1, 'rating': 3}), 1);
      expect(await store.enqueueReview({'card_id': 2, 'rating': 4}), 2);
      expect((await store.outbox()).length, 2);
      // Simulate one synced (the flush removes only the delivered prefix,
      // so an entry enqueued mid-flush can never be clobbered).
      expect(await store.removeFirst(1), 1);
      final left = await store.outbox();
      expect(left.length, 1);
      expect(left.single['card_id'], 2);
      // removeFirst(0) is a pure count read.
      expect(await store.removeFirst(0), 1);
    });

    test('clear() drops snapshot + outbox (sign-out)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [_card(id: 1)],
      );
      await store.enqueueReview({'card_id': 1, 'rating': 3});
      await store.clear();
      expect(await store.loadSnapshot(), isNull);
      expect(await store.outbox(), isEmpty);
    });
  });
}

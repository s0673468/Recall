import 'dart:async';
import 'dart:convert';

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
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/rating_bar.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';

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
  bool cloudSeen = false,
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
  cloudSeen: cloudSeen,
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

  /// Optional cloud recall_prefs row + a record of write-throughs.
  Map<String, dynamic>? recallPrefsRow;
  final List<Map<String, dynamic>> savedRecallPrefs = [];

  /// Records the (newLimit, order) fetchQueue was last called with.
  int? lastNewLimit;
  NewOrder? lastOrder;

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
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    lastNewLimit = newLimit;
    lastOrder = order;
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
  Future<Map<String, dynamic>?> fetchRecallPrefs() async => recallPrefsRow;

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async =>
      savedRecallPrefs.add(value);

  /// Auto-incrementing review_log id handed back per delivery, so undo tests
  /// can assert the flushed row is the one that gets deleted.
  int nextLogId = 900;

  /// Every restore entry undoReview received, in order.
  final List<Map<String, dynamic>> undone = [];
  bool failUndoReview = false;

  /// Awaited inside undoReview — lets tests hold the cloud undo open.
  Future<void> Function()? beforeUndoReview;

  @override
  Future<int?> applyReview(Map<String, dynamic> e) async {
    await beforeApplyReview?.call();
    applied.add(e);
    return ++nextLogId;
  }

  @override
  Future<void> undoReview(Map<String, dynamic> e) async {
    await beforeUndoReview?.call();
    if (failUndoReview) throw StateError('undo failed');
    undone.add(e);
  }

  @override
  Map<String, dynamic> reviewEntry(
    ReviewCard card,
    ReviewOutcome o, {
    int? elapsedMs,
  }) => {'card_id': card.id, 'rating': o.rating, 'elapsed_ms': elapsedMs};

  @override
  Map<String, dynamic> restoreEntry(ReviewCard card) => {
    'card_id': card.id,
    'stability': card.stability,
    'difficulty': card.difficulty,
    'due': card.due?.toIso8601String(),
    'state': card.state,
    'reps': card.reps,
    'lapses': card.lapses,
    'last_review': card.lastReview?.toIso8601String(),
    'cloud_seen': card.cloudSeen,
  };

  /// Fixtures + failure toggles for the stats screen.
  List<ReviewLogEntry> reviewLog = const [];
  List<DateTime> dueDates = const [];
  bool failReviewLog = false;
  bool failDueDates = false;

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    if (failReviewLog) throw StateError('review_log fetch failed');
    return reviewLog;
  }

  @override
  Future<List<DateTime>> fetchDueDates() async {
    if (failDueDates) throw StateError('cards fetch failed');
    return dueDates;
  }

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

    testWidgets('StudyScreen fills in the cloze on flip (plain-summary back)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      // Real-data shape: the answer lives ONLY in the front's {{cN::}} markup;
      // the back is a separate plain summary with no deletion.
      // Distinct card id: the parse memo is a global static keyed by
      // "$cardId:$face", so reusing the default id=1 would collide with the
      // previous StudyScreen test's cached back.
      final controller = ReviewController(
        api: _FakeRecallApi([
          _card(
            id: 507,
            front: '{{c1::mitochondria}} is the powerhouse',
            back: 'A cell organelle.',
          ),
        ]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StudyScreen(controller: controller))),
      );

      // Question side: deletion hidden, answer nowhere on screen.
      expect(find.textContaining('mitochondria'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      // Answer side: the FRONT fills in its deletion (the back is just the
      // summary), so the deleted word is now visible.
      expect(find.textContaining('mitochondria'), findsOneWidget);
      expect(find.textContaining('A cell organelle'), findsOneWidget);
    });
  });

  group('Stats screen', () {
    testWidgets('a failed forecast query does not blank the heatmap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      api.reviewLog = [ReviewLogEntry(at: DateTime.now(), rating: 3)];
      api.failDueDates = true; // only the forecast query fails
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatsScreen(api: api, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Heatmap (review-log query) rendered; forecast (due query) isolated.
      expect(find.byType(ReviewHeatmap), findsOneWidget);
      expect(find.text('Could not load forecast.'), findsOneWidget);
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

    test('removeEntry drops only the matching queued review', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.enqueueReview({'card_id': 1, 'client_id': 11});
      await store.enqueueReview({'card_id': 2, 'client_id': 22});

      var result = await store.removeEntry(22);
      expect(result.removed, isTrue);
      expect(result.remaining, 1);
      expect((await store.outbox()).single['client_id'], 11);

      // Unknown id (already flushed): nothing removed, count untouched.
      result = await store.removeEntry(99);
      expect(result.removed, isFalse);
      expect(result.remaining, 1);
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

  group('RecallPrefsController', () {
    test('loads the cloud row and mirrors it locally', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      api.recallPrefsRow = {
        'new_limit_default': 15,
        'desired_retention': 0.85,
        'new_order': 'random',
      };
      final controller = RecallPrefsController(api: api);
      await controller.load();
      expect(controller.hasStoredPrefs, isTrue);
      expect(controller.value.newLimitDefault, 15);
      expect(controller.value.desiredRetention, 0.85);
      expect(controller.value.newOrder, NewOrder.random);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(RecallPrefsController.localKey), isNotNull);
    });

    test('no cloud row and no mirror stays at defaults (unstored)', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = RecallPrefsController(api: _FakeRecallApi([_card()]));
      await controller.load();
      expect(controller.hasStoredPrefs, isFalse);
      expect(controller.value, const RecallPrefs());
    });

    test('local mirror hydrates before cloud (offline)', () async {
      SharedPreferences.setMockInitialValues({
        RecallPrefsController.localKey: jsonEncode(
          const RecallPrefs(newLimitDefault: 9).toJson(),
        ),
      });
      final controller = RecallPrefsController(api: _FakeRecallApi([_card()]));
      await controller.load();
      expect(controller.value.newLimitDefault, 9);
      expect(controller.hasStoredPrefs, isTrue);
    });

    test('update() writes local + cloud and flips hasStoredPrefs', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      final controller = RecallPrefsController(api: api);
      await controller.update(const RecallPrefs(desiredRetention: 0.8));
      expect(controller.hasStoredPrefs, isTrue);
      expect(api.savedRecallPrefs.single['desired_retention'], 0.8);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(RecallPrefsController.localKey), isNotNull);
    });
  });

  group('ReviewController prefs', () {
    ReviewCard reviewCard() => _card(
      id: 5,
      state: 2,
      stability: 10,
      difficulty: 5,
      reps: 3,
      due: DateTime.utc(2026, 6, 1),
      lastReview: DateTime.utc(2026, 5, 25),
    );

    Future<void> drainUntil(bool Function() cond) async {
      for (var i = 0; i < 200 && !cond(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('fresh install uses limit 20, oldest-first, retention 0.9', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.lastNewLimit, 20);
      expect(api.lastOrder, NewOrder.oldestFirst);
      expect(engine.desiredRetention, 0.9);
    });

    test('cloud prefs drive limit + retention', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      api.recallPrefsRow = {
        'new_limit_default': 7,
        'desired_retention': 0.85,
      };
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.lastNewLimit, 7);
      expect(engine.desiredRetention, 0.85);
    });

    test('per-deck override applies only to that deck', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([
        _card(id: 1, deckId: 1),
        _card(id: 2, deckId: 2),
      ]);
      api.recallPrefsRow = {
        'new_limit_default': 20,
        'per_deck': {'2': {'new_limit': 7}},
      };
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.selectDeck(2);
      expect(api.lastNewLimit, 7);
      await controller.selectDeck(null);
      expect(api.lastNewLimit, 20);
    });

    test('changing retention invalidates and re-prices the preview', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([reviewCard()]);
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();

      final before = controller.previewCurrent()[Rating.good];
      await prefs.update(const RecallPrefs(desiredRetention: 0.97));
      final after = controller.previewCurrent()[Rating.good];
      expect(after, isNot(before));
    });

    test('changing the new-limit reloads the queue', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.lastNewLimit, 20);

      await prefs.update(const RecallPrefs(newLimitDefault: 5));
      await drainUntil(() => api.lastNewLimit == 5);
      expect(api.lastNewLimit, 5);
    });
  });

  group('ReviewController elapsed time', () {
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime.utc(2026, 7, 10, 12);
    });

    ReviewController build(_FakeRecallApi api, {LocalReviewStore? store}) {
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store ?? LocalReviewStore(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('rate stamps elapsed_ms from card display to the rating tap', () async {
      final api = _FakeRecallApi([_card(id: 1)]);
      final controller = build(api);
      await controller.load();

      now = now.add(const Duration(seconds: 3));
      controller.flip(); // revealing the answer must NOT reset the clock
      now = now.add(const Duration(seconds: 2));
      await controller.rate(Rating.good);
      await controller.syncPending();

      expect(api.applied.single['elapsed_ms'], 5000);
    });

    test('elapsed_ms is capped at five minutes and floored at zero', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
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
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
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

    test('an offline review carries the elapsed measured at review time', () async {
      final api = _FakeRecallApi([_card(id: 1)]);
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
    });
  });

  group('ReviewController undo', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    ReviewCard scheduledCard() => _card(
      id: 5,
      state: 2,
      stability: 10,
      difficulty: 5,
      reps: 3,
      lapses: 1,
      due: DateTime.utc(2026, 6, 1),
      lastReview: DateTime.utc(2026, 5, 25),
      cloudSeen: true,
    );

    ReviewController build(_FakeRecallApi api, {LocalReviewStore? store}) {
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store ?? LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('nothing is undoable before the first rating', () async {
      final api = _FakeRecallApi([_card(id: 1)]);
      final controller = build(api);
      await controller.load();
      expect(controller.canUndo, isFalse);
      await controller.undo(); // no-op
      expect(controller.state.index, 0);
      expect(api.undone, isEmpty);
    });

    test('undo of an unflushed review is pure local and empties the outbox', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      api.beforeApplyReview = () async => throw StateError('offline');
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.index, 1);
      expect(controller.state.pendingSync, 1);
      expect(controller.canUndo, isTrue);

      await controller.undo();

      // Back on the same card's front; nothing queued, nothing cloud-side.
      expect(controller.state.index, 0);
      expect(controller.state.showBack, isFalse);
      expect(controller.state.reviewedThisSession, 0);
      expect(controller.state.pendingSync, 0);
      expect(await store.outbox(), isEmpty);
      expect(api.undone, isEmpty);
      expect(controller.canUndo, isFalse);

      // And nothing left behind to double-flush later.
      api.beforeApplyReview = null;
      await controller.syncPending();
      expect(api.applied, isEmpty);
    });

    test('undo of a flushed review restores the card and deletes the log row', () async {
      final api = _FakeRecallApi([scheduledCard(), _card(id: 6)]);
      final controller = build(api);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(api.applied.single['card_id'], 5);

      await controller.undo();

      final restore = api.undone.single;
      expect(restore['card_id'], 5);
      expect(restore['stability'], 10.0);
      expect(restore['difficulty'], 5.0);
      expect(restore['state'], 2);
      expect(restore['reps'], 3);
      expect(restore['lapses'], 1);
      expect(
        restore['last_review'],
        DateTime.utc(2026, 5, 25).toIso8601String(),
      );
      expect(restore['cloud_seen'], isTrue);
      expect(restore['review_log_id'], 901);
      expect(controller.state.index, 0);
      expect(controller.state.showBack, isFalse);
      expect(controller.state.reviewedThisSession, 0);
      expect(controller.canUndo, isFalse);
    });

    test('only the most recent rating can be undone, once', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2), _card(id: 3)]);
      final controller = build(api);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();

      await controller.undo();
      expect(controller.state.index, 1); // back on the second card only
      expect(api.undone.single['card_id'], 2);
      expect(controller.canUndo, isFalse);

      await controller.undo(); // no second level
      expect(controller.state.index, 1);
      expect(api.undone, hasLength(1));
    });

    test('undo waits out an in-flight flush and deletes the row it produced', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      final gate = Completer<void>();
      api.beforeApplyReview = () => gate.future;
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good); // flush starts, stuck on the gate

      final undoing = controller.undo(); // must not treat it as unflushed
      await Future<void>.delayed(Duration.zero);
      expect(api.undone, isEmpty); // still waiting on the flush verdict

      gate.complete();
      await undoing;

      expect(api.applied, hasLength(1));
      expect(api.undone.single['review_log_id'], 901);
      expect(await store.outbox(), isEmpty);
      expect(controller.state.index, 0);
      expect(controller.state.pendingSync, 0);
    });

    test('a failed cloud undo keeps the rating undoable', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      final controller = build(api);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();

      api.failUndoReview = true;
      await controller.undo();
      expect(controller.state.index, 1); // rating stands for now
      expect(controller.canUndo, isTrue); // but the user can retry

      api.failUndoReview = false;
      await controller.undo();
      expect(controller.state.index, 0);
      expect(api.undone, hasLength(1));
    });

    test('a rating attempted while undo is in flight is ignored', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2), _card(id: 3)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending(); // flushed → undo takes the cloud path

      final gate = Completer<void>();
      api.beforeUndoReview = () => gate.future;
      final undoing = controller.undo(); // stuck inside api.undoReview
      await Future<void>.delayed(Duration.zero);
      expect(controller.undoInFlight, isTrue);

      // Mid-flight the user flips and rates the next card — the rating must
      // be ignored, or completion would rewind the queue over it and the
      // card would come back as unrated (double review).
      controller.flip();
      await controller.rate(Rating.good);
      expect(await store.outbox(), isEmpty); // nothing enqueued
      expect(controller.state.index, 1); // no advance

      gate.complete();
      await undoing;

      // The undone card is front-up at its old position with a live badge.
      expect(controller.undoInFlight, isFalse);
      expect(api.undone, hasLength(1));
      expect(controller.state.index, 0);
      expect(controller.state.showBack, isFalse);
      expect(controller.state.reviewedThisSession, 0);
      expect(controller.state.pendingSync, 0);
    });

    test('undo never removes a persisted review with a colliding client_id', () async {
      // An offline flush leaves outbox entries (client_id included) in
      // shared_preferences across an app restart, while the undo sequence
      // restarts from scratch. A stale entry must never be claimed by the
      // fresh session's undo — its id has to be unique across sessions.
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      api.beforeApplyReview = () async => throw StateError('offline');
      final store = LocalReviewStore();
      // The previous session's first rating under a naive counter scheme.
      await store.enqueueReview({'card_id': 99, 'rating': 3, 'client_id': 1});
      final controller = build(api, store: store);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.state.pendingSync, 2);

      await controller.undo();

      // Only this session's review was taken back; the stale one is intact
      // and still deliverable.
      expect(controller.state.index, 0);
      expect(controller.state.pendingSync, 1);
      final left = await store.outbox();
      expect(left.single['card_id'], 99);
      api.beforeApplyReview = null;
      await controller.syncPending();
      expect(api.applied.single['card_id'], 99);
    });

    test('the flush hook ignores a delivered stale entry with a colliding id', () async {
      // Partial flush: the stale (previous-session) entry goes out, this
      // session's review does not. The undo record must NOT be marked
      // flushed by the stale delivery — otherwise undo would delete the
      // stale review's log row and restore state that doesn't match it.
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      api.beforeApplyReview = () async => throw StateError('offline');
      final store = LocalReviewStore();
      await store.enqueueReview({'card_id': 99, 'rating': 3, 'client_id': 1});
      final controller = build(api, store: store);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good); // queued behind the stale entry
      expect(controller.state.pendingSync, 2);

      // Deliver exactly one entry (the stale one), then go offline again.
      var deliveries = 0;
      api.beforeApplyReview = () async {
        if (++deliveries > 1) throw StateError('offline again');
      };
      await controller.syncPending();
      expect(api.applied.single['card_id'], 99);

      await controller.undo();

      // Unflushed path: pure local removal, no review_log delete — the
      // stale review's already-synced log row is left alone.
      expect(api.undone, isEmpty);
      expect(await store.outbox(), isEmpty);
      expect(controller.state.index, 0);
      expect(controller.state.pendingSync, 0);
    });

    test('a queue reload drops the pending undo', () async {
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      final controller = build(api);
      await controller.load();

      controller.flip();
      await controller.rate(Rating.good);
      expect(controller.canUndo, isTrue);

      await controller.refresh();
      expect(controller.canUndo, isFalse);
      await controller.undo(); // no-op after the queue was rebuilt
      expect(api.undone, isEmpty);
    });

    test('undo restarts the elapsed clock', () async {
      var now = DateTime.utc(2026, 7, 10, 12);
      final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load();

      now = now.add(const Duration(seconds: 5));
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(api.applied.single['elapsed_ms'], 5000);

      now = now.add(const Duration(seconds: 100)); // dawdling on card 2
      await controller.undo();

      now = now.add(const Duration(seconds: 3));
      controller.flip();
      await controller.rate(Rating.good);
      await controller.syncPending();
      expect(api.applied.last['elapsed_ms'], 3000);
    });
  });

  group('Undo UI', () {
    testWidgets('StudyScreen undo returns to the previous card front', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: _FakeRecallApi([
          _card(id: 601, front: 'first question', back: 'first answer'),
          _card(id: 602, front: 'second question', back: 'second answer'),
        ]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StudyScreen(controller: controller))),
      );
      expect(find.byTooltip('Undo last rating'), findsNothing);

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      expect(find.textContaining('second question'), findsOneWidget);
      expect(find.byTooltip('Undo last rating'), findsOneWidget);

      await tester.tap(find.byTooltip('Undo last rating'));
      await tester.pumpAndSettle();

      expect(find.textContaining('first question'), findsOneWidget);
      expect(find.text('Show answer'), findsOneWidget);
      expect(find.byTooltip('Undo last rating'), findsNothing);
    });

    testWidgets('the all-caught-up screen still offers undo', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: _FakeRecallApi([
          _card(id: 603, front: 'only question', back: 'only answer'),
        ]),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StudyScreen(controller: controller))),
      );

      await tester.tap(find.text('Show answer'));
      await tester.pump();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      // Rated the last card straight into the done state — a mis-tap here
      // must still be recoverable.
      expect(find.text('All caught up'), findsOneWidget);
      await tester.tap(find.text('Undo last rating'));
      await tester.pumpAndSettle();

      expect(find.textContaining('only question'), findsOneWidget);
      expect(find.text('Show answer'), findsOneWidget);
    });
  });
}

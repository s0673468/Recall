import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating, defaultParameters;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, SupabaseClient, User;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/remediation_service.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/data/review_replay.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/rating_bar.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';
import 'package:health_anki_flutter/navigation/recall_deep_links.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

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
  String? tags,
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
  tags: tags,
);

/// One row of the modelled `cards` table — the mutable server-side scheduling
/// state a replay merges into.
class _ServerCard {
  double? stability;
  double? difficulty;
  DateTime? due;
  int state;
  int reps;
  int lapses;
  DateTime? lastReview;
  bool cloudSeen;

  _ServerCard({
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.state,
    required this.reps,
    required this.lapses,
    required this.lastReview,
    required this.cloudSeen,
  });

  factory _ServerCard.from(ReviewCard c) => _ServerCard(
    stability: c.stability,
    difficulty: c.difficulty,
    due: c.due,
    state: c.state,
    reps: c.reps,
    lapses: c.lapses,
    lastReview: c.lastReview,
    cloudSeen: c.cloudSeen,
  );

  /// Apply a PATCH: only the columns actually present in [values] move, which
  /// is what lets a stale replay update `reps`/`lapses` while leaving the
  /// newer device's scheduling untouched.
  void patch(Map<String, dynamic> values) {
    for (final entry in values.entries) {
      switch (entry.key) {
        case 'stability':
          stability = (entry.value as num?)?.toDouble();
        case 'difficulty':
          difficulty = (entry.value as num?)?.toDouble();
        case 'due':
          due = entry.value == null
              ? null
              : DateTime.parse(entry.value as String);
        case 'state':
          state = (entry.value as num).toInt();
        case 'reps':
          reps = (entry.value as num).toInt();
        case 'lapses':
          lapses = (entry.value as num).toInt();
        case 'last_review':
          lastReview = entry.value == null
              ? null
              : DateTime.parse(entry.value as String);
        case 'cloud_seen':
          cloudSeen = entry.value as bool;
      }
    }
  }
}

/// Raised when an insert violates the modelled `(card_id, client_event_id)`
/// unique index — the constraint that makes replay idempotent server-side.
class _DuplicateEventError extends Error {
  final int cardId;
  final String clientEventId;
  _DuplicateEventError(this.cardId, this.clientEventId);

  @override
  String toString() =>
      'duplicate key: (card_id, client_event_id) = ($cardId, $clientEventId)';
}

/// The shared server two devices sync against: a card table keyed by id and an
/// append-only review log with a real uniqueness constraint. Pass one instance
/// to several [_FakeRecallApi]s to model a multi-device collection.
class _FakeServer {
  final Map<int, _ServerCard> cards = {};
  final List<Map<String, dynamic>> reviewLog = [];

  /// Matches the previous recorder's numbering so existing undo tests keep
  /// asserting the same review_log ids.
  int nextLogId = 900;

  /// Awaited inside the guarded card update — lets a test interleave another
  /// device's write and force the compare-and-swap to lose.
  Future<void> Function()? beforeCardUpdate;

  void seed(ReviewCard card) =>
      cards.putIfAbsent(card.id, () => _ServerCard.from(card));

  int? findLogByEventId(int cardId, String clientEventId) {
    for (final row in reviewLog) {
      if (row['card_id'] == cardId &&
          row['client_event_id'] == clientEventId) {
        return row['id'] as int;
      }
    }
    return null;
  }

  int? findLogLegacy(int cardId, Object? ratingAt, Object? device) {
    for (final row in reviewLog.reversed) {
      if (row['card_id'] == cardId &&
          row['rating_at'] == ratingAt &&
          row['device'] == device) {
        return row['id'] as int;
      }
    }
    return null;
  }

  int appendLog(Map<String, dynamic> entry, {String? clientEventId}) {
    final cardId = (entry['card_id'] as num).toInt();
    if (clientEventId != null &&
        findLogByEventId(cardId, clientEventId) != null) {
      throw _DuplicateEventError(cardId, clientEventId);
    }
    final id = ++nextLogId;
    reviewLog.add({
      'id': id,
      'card_id': cardId,
      'guid': entry['guid'],
      'rating': entry['rating'],
      'rating_at': entry['last_review'],
      'device': entry['device'],
      'client_event_id': clientEventId,
    });
    return id;
  }

  void deleteLog(Object? logId) =>
      reviewLog.removeWhere((row) => row['id'] == logId);
}

class _FakeRecallApi implements RecallApi {
  final List<ReviewCard> queue;
  final FsrsSettings? fsrsSettings;

  /// The server this device syncs against. Two fakes sharing one instance is
  /// how a two-device conflict is expressed.
  final _FakeServer server;

  /// Overridable so two devices in one test are distinguishable in the log.
  final String deviceLabel;

  User? user;
  Map<int, ({int due, int neu})> deckCounts = const {};
  bool failDeckCounts = false;
  int queueFetches = 0;

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

  _FakeRecallApi(
    this.queue, {
    this.fsrsSettings,
    _FakeServer? server,
    this.deviceLabel = 'test',
  }) : server = server ?? _FakeServer() {
    for (final card in queue) {
      this.server.seed(card);
    }
  }

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  User? get currentUser => user;

  @override
  String get device => deviceLabel;

  /// The queue as the *server* currently holds it: card content from the
  /// fixture, scheduling state from the card table. A device that loads after
  /// another has synced therefore sees the other's work, which is what makes a
  /// divergent second review expressible.
  ReviewCard _project(ReviewCard template) {
    final row = server.cards[template.id];
    if (row == null) return template;
    return ReviewCard(
      id: template.id,
      guid: template.guid,
      deckId: template.deckId,
      front: template.front,
      back: template.back,
      hasLatex: template.hasLatex,
      stability: row.stability,
      difficulty: row.difficulty,
      due: row.due,
      state: row.state,
      reps: row.reps,
      lapses: row.lapses,
      lastReview: row.lastReview,
      cloudSeen: row.cloudSeen,
      tags: template.tags,
      latexSvg: template.latexSvg,
    );
  }

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
    queueFetches++;
    lastNewLimit = newLimit;
    lastOrder = order;
    await beforeQueue?.call();
    return [
      for (final c in queue)
        if (deckId == null || c.deckId == deckId) _project(c),
    ];
  }

  /// How many bonus batches were fetched, mirroring [queueFetches].
  int aheadFetches = 0;

  /// Mirrors the production query shape: server-projected cards due within
  /// the horizon (soonest first), topped up with unseen new cards.
  @override
  Future<List<ReviewCard>> fetchAheadQueue({
    int? deckId,
    Duration horizon = const Duration(hours: 24),
    int limit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    aheadFetches++;
    final cutoff = DateTime.now().toUtc().add(horizon);
    final all = [
      for (final c in queue)
        if (deckId == null || c.deckId == deckId) _project(c),
    ];
    final ahead = [
      for (final c in all)
        if (c.state != 0 && c.due != null && !c.due!.isAfter(cutoff)) c,
    ]..sort((a, b) => a.due!.compareTo(b.due!));
    final fresh = [
      for (final c in all)
        if (c.state == 0) c,
    ];
    return [
      ...ahead.take(limit),
      ...fresh.take((limit - ahead.length).clamp(0, limit)),
    ];
  }

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async => fsrsSettings;

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async => recallPrefsRow;

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async =>
      savedRecallPrefs.add(value);

  /// Every restore entry undoReview received, in order.
  final List<Map<String, dynamic>> undone = [];
  bool failUndoReview = false;
  bool signedOut = false;

  /// Awaited inside undoReview — lets tests hold the cloud undo open.
  Future<void> Function()? beforeUndoReview;

  /// Mirrors `RecallApi.applyReview` step for step: suppress a duplicate off
  /// the log's uniqueness constraint, merge through the *production* replay
  /// algorithm, then append the log row. Only the transport is fake.
  @override
  Future<int?> applyReview(Map<String, dynamic> e) async {
    await beforeApplyReview?.call();
    final cardId = (e['card_id'] as num).toInt();
    final eventId = e['client_id']?.toString();
    final existing = eventId != null
        ? server.findLogByEventId(cardId, eventId)
        : server.findLogLegacy(cardId, e['last_review'], e['device']);
    if (existing != null) return existing;

    await applyMergedReview(this, e);
    if (failLogInsert) throw StateError('review_log insert failed');
    applied.add(e);
    return server.appendLog(e, clientEventId: eventId);
  }

  @override
  Future<CardSyncState?> readCardState(int cardId) async {
    final row = server.cards[cardId];
    return row == null
        ? null
        : CardSyncState(
            reps: row.reps,
            lapses: row.lapses,
            lastReview: row.lastReview?.toUtc(),
          );
  }

  @override
  Future<int> updateCardWhereReps(
    int cardId, {
    required int? expectedReps,
    required Map<String, dynamic> values,
  }) async {
    await server.beforeCardUpdate?.call();
    final row = server.cards[cardId];
    if (row == null || row.reps != expectedReps) return 0;
    row.patch(values);
    return 1;
  }

  /// Every flag applyFlag delivered, in order.
  final List<Map<String, dynamic>> flagged = [];

  /// When true, applyFlag throws — simulates the note_flags table not existing.
  bool failApplyFlag = false;

  /// When true, the card merge commits but appending the log row throws —
  /// the partial-apply window between applyReview's two writes.
  bool failLogInsert = false;

  /// Awaited inside applyFlag — lets tests hold the flag flush open.
  Future<void> Function()? beforeApplyFlag;

  @override
  Future<void> applyFlag(Map<String, dynamic> e) async {
    await beforeApplyFlag?.call();
    if (failApplyFlag) throw StateError('note_flags missing');
    flagged.add(e);
  }

  @override
  Future<void> undoReview(Map<String, dynamic> e) async {
    await beforeUndoReview?.call();
    if (failUndoReview) throw StateError('undo failed');
    undone.add(e);
    // Undo is a straight restore of the pre-rating snapshot (unguarded, like
    // production) plus the log-row delete.
    server.cards[(e['card_id'] as num).toInt()]?.patch(e);
    server.deleteLog(e['review_log_id']);
  }

  @override
  Map<String, dynamic> reviewEntry(
    ReviewCard card,
    ReviewOutcome o, {
    int? elapsedMs,
  }) => {
    'card_id': card.id,
    'guid': card.guid,
    'stability': o.stability,
    'difficulty': o.difficulty,
    'due': o.due.toIso8601String(),
    'state': o.state,
    'reps': o.reps,
    'lapses': o.lapses,
    'last_review': o.reviewedAt.toIso8601String(),
    'rating': o.rating,
    'elapsed_ms': elapsedMs,
    'device': device,
    'lapsed': o.lapses > card.lapses,
  };

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
  Map<String, String> noteTags = const {};
  List<ConceptNodeInfo> conceptNodes = const [];
  List<ConceptPage> conceptPages = const [];
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
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async {
    if (failDeckCounts) throw StateError('deck count RPC unavailable');
    return deckCounts;
  }

  @override
  Future<Map<String, String>> fetchNoteTags() async => noteTags;

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => conceptNodes;

  @override
  Future<List<ConceptPage>> fetchConceptPages() async => conceptPages;

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signOut() async => signedOut = true;
}

class _GatedFsrsRecallApi extends _FakeRecallApi {
  final StreamController<AuthState> authStates =
      StreamController<AuthState>.broadcast();
  final Completer<void> fsrsStarted = Completer<void>();
  final Completer<void> releaseFsrs = Completer<void>();

  _GatedFsrsRecallApi(super.queue, {super.fsrsSettings});

  @override
  Stream<AuthState> get onAuthStateChange => authStates.stream;

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async {
    fsrsStarted.complete();
    await releaseFsrs.future;
    return fsrsSettings;
  }
}

class _SilentLinkSource implements RecallLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get links => const Stream.empty();
}

Future<void> _enqueuePendingReview({
  required LocalReviewStore store,
  required RecallApi api,
  required ReviewCard card,
}) async {
  final outcome = FsrsEngine().review(
    card,
    Rating.good,
    now: DateTime.utc(2026, 8, 1, 12),
  );
  final entry = api.reviewEntry(card, outcome);
  entry['client_id'] = await store.newEventId();
  await store.enqueueReview(entry);
}

void main() {
  test('review events identify the native iOS client', () {
    expect(
      recallDeviceLabel(isWeb: false, targetPlatform: TargetPlatform.iOS),
      'ios',
    );
    expect(
      recallDeviceLabel(isWeb: false, targetPlatform: TargetPlatform.android),
      'android',
    );
    expect(
      recallDeviceLabel(isWeb: true, targetPlatform: TargetPlatform.iOS),
      'web',
    );
  });

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

    test('preview is stable and matches the interval persisted on tap', () {
      // Regression for the reported mature-card profile: its UI showed
      // Hard 5d / Good 5d / Easy 16d, but tapping Good actually persisted 8d.
      // The package's random fuzz was drawn separately for each preview and
      // again for the tap.
      final configured = FsrsEngine(parameters: _desktopFsrsParameters);
      final card = _card(
        id: 42,
        state: 2,
        stability: 2.17292,
        difficulty: 5.08338,
        reps: 2,
        due: DateTime.utc(2026, 7, 30, 9, 50, 23, 757, 335),
        lastReview: DateTime.utc(2026, 7, 28, 9, 50, 23, 757, 335),
      );
      final reviewedAt = DateTime.utc(2026, 7, 30, 12, 22, 39, 421, 193);
      final expected = {
        Rating.again: const Duration(minutes: 10),
        Rating.hard: const Duration(days: 5),
        Rating.good: const Duration(days: 8),
        Rating.easy: const Duration(days: 15),
      };

      for (var attempt = 0; attempt < 10; attempt++) {
        final preview = configured.preview(card, now: reviewedAt);
        for (final rating in Rating.values) {
          expect(preview[rating]!.difference(reviewedAt), expected[rating]);
          expect(
            configured.review(card, rating, now: reviewedAt).due,
            preview[rating],
          );
        }
      }
    });

    test('preview restores a persisted relearning card without its step', () {
      final p = engine.preview(
        _card(
          id: 3,
          state: 3,
          stability: 3,
          difficulty: 6,
          reps: 3,
          lapses: 1,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        now: now,
      );

      expect(p.keys.toSet(), Rating.values.toSet());
    });

    test('Good graduates a learning card whose last gap was the final step', () {
      // Persisted rows carry no `step`. This card's last scheduled gap was the
      // 10-minute (final) learning step, so Good must graduate it to days —
      // restoring it at step 0 would loop it at 10 minutes forever.
      final out = engine.review(
        _card(
          id: 4,
          state: 1,
          stability: 1.5,
          difficulty: 5,
          reps: 1,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 2);
      expect(
        out.due.difference(now),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
    });

    test('Good moves a step-0 learning card to the next step, not out', () {
      // Last gap ≈ the 1-minute step (an Again press) — still step 0, so Good
      // advances to the 10-minute step rather than graduating.
      final out = engine.review(
        _card(
          id: 5,
          state: 1,
          stability: 1.0,
          difficulty: 5,
          reps: 2,
          due: now.subtract(const Duration(seconds: 30)),
          lastReview: now.subtract(const Duration(seconds: 90)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 1);
      expect(out.due.difference(now), lessThan(const Duration(minutes: 15)));
    });

    test('loop-inflated learning stability is clamped on graduation', () {
      // Cards stuck in the pre-#12 learning loop had their stability
      // compounded to weeks or months. A card still in learning can't have
      // legitimately earned more than a first Good press (~w[2] days), so
      // Good must graduate it to days — not the months its row claims.
      final out = engine.review(
        _card(
          id: 7,
          state: 1,
          stability: 117.4,
          difficulty: 5,
          reps: 9,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 2);
      expect(
        out.due.difference(now),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
      expect(out.due.difference(now), lessThan(const Duration(days: 10)));
    });

    test('relearning cards keep their real stability (no clamp)', () {
      // A lapsed mature card legitimately carries large stability through
      // relearning — graduating it back out must respect that.
      final out = engine.review(
        _card(
          id: 8,
          state: 3,
          stability: 60,
          difficulty: 5,
          reps: 12,
          lapses: 2,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        Rating.good,
        now: now,
      );
      expect(out.state, 2);
      expect(
        out.due.difference(now),
        greaterThan(const Duration(days: 30)),
      );
    });

    test('rating previews show no cliff between Good and Easy', () {
      // The bug this pins down: Good previewing ~10 minutes while Easy
      // previews months, with nothing in between.
      final p = engine.preview(
        _card(
          id: 6,
          state: 1,
          stability: 1.5,
          difficulty: 5,
          reps: 1,
          due: now.subtract(const Duration(minutes: 1)),
          lastReview: now.subtract(const Duration(minutes: 11)),
        ),
        now: now,
      );
      expect(
        p[Rating.good]!.difference(now),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
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
    test(
      'a corrupt durable outbox becomes a recoverable startup error',
      () async {
        SharedPreferences.setMockInitialValues({
          'recall_outbox_v1': '{not valid json',
        });
        final controller = ReviewController(
          api: _FakeRecallApi([_card()]),
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
        final api = _FakeRecallApi([_card()]);
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
        final api = _FakeRecallApi([_card()]);
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
        final api = _FakeRecallApi([_card(id: 42)])
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
          api: _FakeRecallApi([_card(id: 42)]),
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
        final api = _FakeRecallApi([
          _card(state: 2, due: now.subtract(const Duration(hours: 1))),
        ])..deckCounts = const {1: (due: 3, neu: 2), 2: (due: 4, neu: 9)};
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

    test(
      'keepGoing cards due later do not reduce the cloud due count',
      () async {
        SharedPreferences.setMockInitialValues({});
        final api = _FakeRecallApi([
          _card(
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
        final api = _FakeRecallApi([
          _card(
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
        final api = _FakeRecallApi([
          _card(
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
      final api = _FakeRecallApi([_card()])..failDeckCounts = true;
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
        decks: const [DeckRow(deckId: 1, name: 'Portuguese')],
        queue: [_card(state: 2, due: now.subtract(const Duration(hours: 1)))],
        globalDueCount: 10,
        globalDueUpdatedAt: now.subtract(const Duration(minutes: 30)),
      );
      final queueStarted = Completer<void>();
      final releaseQueue = Completer<void>();
      final api = _FakeRecallApi([
        _card(state: 2, due: now.subtract(const Duration(hours: 1))),
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
      final api = _FakeRecallApi(const [])
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
      final api = _FakeRecallApi([_card()])
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
      final controller = ReviewController(
        api: _FakeRecallApi([_card()]),
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
        api: _FakeRecallApi(const []),
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

    test('a superseded load cannot reapply signed-out FSRS settings', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _GatedFsrsRecallApi(
        [_card()],
        fsrsSettings: const FsrsSettings(
          parameters: _desktopFsrsParameters,
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

    test('offline restart never repaints cards with pending reviews', () async {
      SharedPreferences.setMockInitialValues({});
      final cards = [_card(id: 1), _card(id: 2)];
      final store = LocalReviewStore();
      final firstApi = _FakeRecallApi(cards)
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
      final restartApi = _FakeRecallApi(cards);
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
        final cards = [_card(id: 1), _card(id: 2), _card(id: 3)];
        final store = LocalReviewStore();
        final api = _FakeRecallApi(cards);
        await _enqueuePendingReview(store: store, api: api, card: cards[0]);
        await _enqueuePendingReview(store: store, api: api, card: cards[1]);
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
        expect(
          (await store.loadSnapshot())!.queue.map((card) => card.id),
          [3],
        );
      },
    );

    test('a fully flushed outbox does not filter the fetched queue', () async {
      SharedPreferences.setMockInitialValues({});
      final cards = [_card(id: 1), _card(id: 2), _card(id: 3)];
      final store = LocalReviewStore();
      final api = _FakeRecallApi(cards);
      await _enqueuePendingReview(store: store, api: api, card: cards[0]);
      await _enqueuePendingReview(store: store, api: api, card: cards[1]);
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
        final cards = [_card(id: 1), _card(id: 2)];
        final store = LocalReviewStore();
        await store.saveSnapshot(
          decks: const [DeckRow(deckId: 1, name: 'Portuguese')],
          queue: cards,
        );
        final api = _FakeRecallApi(cards);
        await _enqueuePendingReview(store: store, api: api, card: cards[0]);
        await _enqueuePendingReview(store: store, api: api, card: cards[1]);
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

    test(
      'rate advances to the next card without waiting on the sync',
      () async {
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
      },
    );

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

    test(
      'a rating enqueued mid-flush is delivered by the follow-up pass',
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
      },
    );
  });

  group('Local primer remediation', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('only a true lapse enqueues a tagged concept', () async {
      final card = _card(
        id: 401,
        state: 2,
        reps: 3,
        due: DateTime.utc(2026, 7, 1),
        tags: 'node::m00-vector-geometry',
      );
      final api = _FakeRecallApi([card]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.current?.tags, 'node::m00-vector-geometry');
      controller.flip();
      await controller.rate(Rating.again);

      expect((await store.outbox()).single['lapsed'], isTrue);
      await controller.syncPending();
      expect(api.applied, hasLength(1));
      expect(api.applied.single['lapsed'], isTrue);
      expect((await store.remediationQueue()).map((item) => item.nodeId), [
        'm00-vector-geometry',
      ]);
    });

    test('learning Again does not become a remediation lapse', () async {
      final api = _FakeRecallApi([
        _card(id: 402, state: 1, tags: 'node::m00-learning'),
        _card(
          id: 403,
          state: 2,
          reps: 3,
          due: DateTime.utc(2026, 7, 1),
          tags: 'node::m00-review',
        ),
      ]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      controller.flip();
      await controller.rate(Rating.again);
      controller.flip();
      await controller.rate(Rating.again);
      await controller.syncPending();

      expect(api.applied[0]['rating'], Rating.again.value);
      expect(api.applied[0]['lapsed'], isFalse);
      expect(api.applied[1]['lapsed'], isTrue);
      expect((await store.remediationQueue()).map((item) => item.nodeId), [
        'm00-review',
      ]);
    });

    test('remediation is local and does not add a scheduling write', () async {
      final card = _card(
        id: 404,
        state: 2,
        reps: 3,
        due: DateTime.utc(2026, 7, 1),
        tags: 'node::m00-vector-geometry',
      );
      final api = _FakeRecallApi([card]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      controller.flip();
      await controller.rate(Rating.again);
      await controller.syncPending();

      expect(api.applied, hasLength(1));
      expect(api.server.cards[card.id]!.lapses, 1);
      expect(await store.outbox(), isEmpty);
      expect(await store.remediationQueue(), hasLength(1));
    });

    test(
      'same-day remediation is capped, deduplicated, and survives restart',
      () async {
        final now = DateTime(2026, 8, 5, 12);
        final store = LocalReviewStore();
        await store.enqueueRemediation([
          'm00-a',
          'm00-b',
          'm00-a',
          'm00-c',
          'm00-d',
        ], now: now);

        final restarted = LocalReviewStore();
        expect(
          (await restarted.remediationQueue(
            now: now,
          )).map((item) => item.nodeId),
          ['m00-a', 'm00-b', 'm00-c'],
        );
        await restarted.enqueueRemediation(['m00-b', 'm00-d'], now: now);
        expect(
          (await restarted.remediationQueue(
            now: now,
          )).map((item) => item.nodeId),
          ['m00-a', 'm00-b', 'm00-c'],
        );

        expect(await restarted.completeRemediation('m00-b', now: now), isTrue);
        expect(
          (await restarted.remediationQueue(
            now: now,
          )).map((item) => item.nodeId),
          ['m00-a', 'm00-c'],
        );
      },
    );

    test('unresolved ids and primers read today are skipped', () {
      final queuedAt = DateTime(2026, 8, 5, 12);
      final pages = [
        ConceptPage(
          nodeId: 'm00-read',
          title: 'Already read',
          bodyHtml: 'Read',
          updatedAt: queuedAt,
        ),
        ConceptPage(
          nodeId: 'm00-unread',
          title: 'Needs reread',
          bodyHtml: 'Unread',
          updatedAt: queuedAt,
        ),
      ];
      final visible = visibleRemediationPages(
        queue: [
          LocalRemediationItem(nodeId: 'm00-read', queuedAt: queuedAt),
          LocalRemediationItem(nodeId: 'm99-missing', queuedAt: queuedAt),
          LocalRemediationItem(nodeId: 'm00-unread', queuedAt: queuedAt),
        ],
        conceptNodes: const [
          ConceptNodeInfo(nodeId: 'm00-read', title: 'Read', module: 'M00'),
          ConceptNodeInfo(
            nodeId: 'm00-unread',
            title: 'Unread',
            module: 'M00',
          ),
        ],
        conceptPages: pages,
        readTodayPages: [pages.first],
      );

      expect(visible.map((page) => page.nodeId), ['m00-unread']);
    });

    testWidgets('done state renders and completes reread rows', (tester) async {
      final page = ConceptPage(
        nodeId: 'm00-vector-geometry',
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime(2026, 8, 5),
      );
      final api = _FakeRecallApi(const [])
        ..conceptNodes = const [
          ConceptNodeInfo(
            nodeId: 'm00-vector-geometry',
            title: 'Vector geometry',
            module: 'M00',
          ),
        ]
        ..conceptPages = [page];
      final store = LocalReviewStore();
      await store.enqueueRemediation(['m00-vector-geometry']);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyScreen(controller: controller, api: api, store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('All caught up'), findsOneWidget);
      expect(find.text('Reread: Vector geometry primer'), findsOneWidget);
      await tester.tap(find.text('Reread: Vector geometry primer'));
      await tester.pumpAndSettle();
      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.byType(PrimerScreen), findsOneWidget);

      Navigator.of(tester.element(find.byType(PrimerScreen))).pop();
      await tester.pumpAndSettle();
      expect(await store.remediationQueue(), isEmpty);
    });
  });

  group('Multi-device sync', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    /// A card both devices already hold: reviewed three times, lapsed once.
    ReviewCard studied() => _card(
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

    /// One device's queued review of that card. `reps`/`lapses` carry the
    /// absolute values computed off *this* device's snapshot — the numbers the
    /// unguarded replay used to write straight through.
    Map<String, dynamic> event({
      required String device,
      required DateTime at,
      required int rating,
      required int state,
      required bool lapsed,
      required double stability,
    }) => {
      'card_id': 5,
      'guid': 'g5',
      'stability': stability,
      'difficulty': 5.0,
      'due': at.add(const Duration(days: 10)).toIso8601String(),
      'state': state,
      'reps': 4,
      'lapses': lapsed ? 2 : 1,
      'last_review': at.toIso8601String(),
      'rating': rating,
      'device': device,
      'client_id': '$device-event-1',
      'lapsed': lapsed,
    };

    final morning = event(
      device: 'phone',
      at: DateTime.utc(2026, 6, 10, 9),
      rating: 3,
      state: 2,
      lapsed: false,
      stability: 20,
    );
    final evening = event(
      device: 'ipad',
      at: DateTime.utc(2026, 6, 10, 17),
      rating: 1,
      state: 3,
      lapsed: true,
      stability: 2,
    );

    /// Two devices, one server, flushing in the given order.
    Future<_ServerCard> syncInOrder(List<Map<String, dynamic>> order) async {
      final server = _FakeServer();
      final devices = {
        'phone': _FakeRecallApi(
          [studied()],
          server: server,
          deviceLabel: 'phone',
        ),
        'ipad': _FakeRecallApi([studied()], server: server, deviceLabel: 'ipad'),
      };
      for (final e in order) {
        await devices[e['device']]!.applyReview(e);
      }
      return server.cards[5]!;
    }

    test('two offline devices converge whichever order they sync', () async {
      final forward = await syncInOrder([morning, evening]);
      final reverse = await syncInOrder([evening, morning]);

      for (final card in [forward, reverse]) {
        // Both reviews really happened, so both are counted — accumulated from
        // server state rather than taken from either device's snapshot.
        expect(card.reps, 5);
        expect(card.lapses, 2);
        // The later review owns the schedule no matter when it arrives.
        expect(card.lastReview, DateTime.utc(2026, 6, 10, 17));
        expect(card.state, 3);
        expect(card.stability, 2);
      }
    });

    test('a late replay counts its rep without rewinding the card', () async {
      // Evening synced first; the morning review arrives afterwards. Its older
      // scheduling must not drag the card back to a due date already superseded.
      final api = _FakeRecallApi([studied()]);
      await api.applyReview(evening);
      final scheduledDue = api.server.cards[5]!.due;

      await api.applyReview(morning);

      final card = api.server.cards[5]!;
      expect(card.due, scheduledDue);
      expect(card.stability, 2);
      expect(card.state, 3);
      expect(card.reps, 5); // still counted
    });

    test('reps and lapses never take a stale absolute snapshot', () async {
      // Both entries claim `reps: 4` off their own stale local card. Writing
      // either one through verbatim would lose the other device's review.
      final api = _FakeRecallApi([studied()]);
      await api.applyReview(morning);
      expect(api.server.cards[5]!.reps, 4);
      expect(api.server.cards[5]!.lapses, 1);

      await api.applyReview(evening);
      expect(api.server.cards[5]!.reps, 5);
      expect(api.server.cards[5]!.lapses, 2);
    });

    test('a lost compare-and-swap re-merges instead of clobbering', () async {
      final api = _FakeRecallApi([studied()]);
      // Another device commits between this replay's read and its write.
      var interposed = false;
      api.server.beforeCardUpdate = () async {
        if (interposed) return;
        interposed = true;
        api.server.cards[5]!
          ..reps += 1
          ..lastReview = DateTime.utc(2026, 6, 10, 12);
      };

      await api.applyReview(morning);

      expect(interposed, isTrue);
      // The interloper's rep survived and ours landed on top of it.
      expect(api.server.cards[5]!.reps, 5);
      // Its review was newer than ours, so it kept the schedule.
      expect(api.server.cards[5]!.lastReview, DateTime.utc(2026, 6, 10, 12));
    });

    test('a permanently contended card defers rather than corrupts', () async {
      final api = _FakeRecallApi([studied()]);
      api.server.beforeCardUpdate = () async => api.server.cards[5]!.reps += 1;

      await expectLater(
        api.applyReview(morning),
        throwsA(isA<ReviewReplayConflict>()),
      );
      // Nothing logged: the review stays in the outbox for the next flush.
      expect(api.server.reviewLog, isEmpty);
    });

    test('a retry after a failed log insert does not double-count', () async {
      // applyReview merges the card first, then appends the log. A failure in
      // between leaves the outbox entry queued with no log row, so the next
      // flush's client_event_id probe finds nothing and retries the whole
      // apply. Since counters now accumulate from server state, repeating the
      // merge would inflate reps — the merge has to notice it already landed.
      final api = _FakeRecallApi([studied()])..failLogInsert = true;

      await expectLater(api.applyReview(morning), throwsA(isA<StateError>()));
      expect(api.server.cards[5]!.reps, 4); // card merged
      expect(api.server.reviewLog, isEmpty); // log did not

      api.failLogInsert = false;
      await api.applyReview(morning); // the outbox retries it

      expect(api.server.cards[5]!.reps, 4); // not 5
      expect(api.server.cards[5]!.lapses, 1);
      expect(api.server.reviewLog, hasLength(1));
    });

    test('an exact timestamp tie leaves the first writer alone', () async {
      // Strict `isAfter` means equal timestamps do not win the schedule, so
      // two devices rating in the same instant resolve first-writer-wins
      // rather than thrashing on flush order.
      final api = _FakeRecallApi([studied()]);
      final tie = {
        ...evening,
        'client_id': 'other-device',
        'stability': 99.0,
      };

      await api.applyReview(evening);
      await api.applyReview(tie);

      expect(api.server.cards[5]!.stability, 2); // first writer's scheduling
      // KNOWN RESIDUAL, pinned deliberately: the tie is indistinguishable from
      // our own partial apply, so the second review's rep is dropped — reps is
      // 4, not the 5 the "both reviews count" policy would give. Both events
      // are still logged, so the history is complete and the count is
      // recoverable. Fixing this needs true per-client_event_id idempotency
      // (a transactional RPC); see the README.
      expect(api.server.cards[5]!.reps, 4);
      expect(api.server.reviewLog, hasLength(2));
    });

    test('an unreadable last_review writes nothing at all', () async {
      // Failing closed on the whole row, not just the scheduling: a
      // counters-only patch would leave last_review untouched, so every retry
      // of this entry would add another phantom rep with no way to detect the
      // earlier merge.
      final server = CardSyncState.fromRow({
        'reps': 9,
        'lapses': 2,
        'last_review': 'not-a-timestamp',
      });

      expect(server.lastReviewUnreadable, isTrue);
      expect(mergeReviewIntoCard(server: server, entry: morning), isEmpty);
    });

    test('a never-reviewed card takes the incoming scheduling', () {
      // last_review IS NULL means nobody has reviewed it, so this review is
      // unambiguously the newest thing the row has ever seen.
      final server = CardSyncState.fromRow({
        'reps': 0,
        'lapses': 0,
        'last_review': null,
      });

      expect(server.lastReviewUnreadable, isFalse);
      final values = mergeReviewIntoCard(server: server, entry: morning);
      expect(values['due'], morning['due']);
      expect(values['reps'], 1);
    });

    test('a colliding client_event_id discards a genuine review', () async {
      // Why the durable id has to be unique: the server dedupes on it alone,
      // so two different reviews wearing the same id collapse into one.
      final api = _FakeRecallApi([studied()]);
      final second = {...evening, 'client_id': morning['client_id']};

      await api.applyReview(morning);
      await api.applyReview(second);

      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[5]!.reps, 4); // the evening review vanished
    });

    test(
      'a restart with a rolled-back clock still delivers both reviews',
      () async {
        // The outbox survives a restart but the in-memory counters do not. If
        // the durable id were only clock+counter, a device whose clock rolled
        // back to the same instant would mint the same id twice and the server
        // would discard the second review as a replay.
        final at = DateTime.utc(2026, 7, 20, 12);
        final server = _FakeServer();
        final store = LocalReviewStore();
        ReviewCard due(int id) => _card(
          id: id,
          state: 2,
          stability: 10,
          difficulty: 5,
          reps: 3,
          due: DateTime.utc(2026, 7, 1),
          lastReview: DateTime.utc(2026, 6, 25),
        );

        Future<ReviewController> session(ReviewCard card) async {
          final api = _FakeRecallApi([card], server: server)
            ..beforeApplyReview = () async => throw StateError('offline');
          final controller = ReviewController(
            api: api,
            engine: FsrsEngine(),
            store: store,
            clock: () => at,
          );
          await controller.load();
          controller.flip();
          await controller.rate(Rating.good);
          return controller;
        }

        final first = await session(due(1));
        first.dispose(); // app killed; sequence counters reset
        // A pending card is intentionally not served again after WP1. Use a
        // second real card to keep this ID-uniqueness fixture realizable.
        final second = await session(due(2));
        addTearDown(second.dispose);

        final queued = await store.outbox();
        expect(queued, hasLength(2));
        expect(queued[0]['client_id'], isNot(queued[1]['client_id']));

        // Back online: both must land as separate reviews.
        final api = _FakeRecallApi([due(1), due(2)], server: server);
        final online = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => at,
        );
        addTearDown(online.dispose);
        await online.syncPending();

        expect(await store.outbox(), isEmpty);
        expect(server.reviewLog, hasLength(2));
        expect(server.cards[1]!.reps, 4);
        expect(server.cards[2]!.reps, 4);
      },
    );
  });

  group('UI widgets', () {
    test('rating intervals round future time up instead of shaving a unit', () {
      expect(
        humanizeRatingInterval(
          const Duration(minutes: 10) - const Duration(milliseconds: 1),
        ),
        '10m',
      );
      expect(
        humanizeRatingInterval(
          const Duration(days: 6) - const Duration(milliseconds: 1),
        ),
        '6d',
      );
    });

    testWidgets('rating intervals stay anchored to the preview timestamp', (
      tester,
    ) async {
      final previewAt = DateTime.now().toUtc().subtract(
        const Duration(minutes: 4),
      );
      final due = previewAt.add(const Duration(minutes: 10));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RatingBar(
              preview: {for (final r in Rating.values) r: due},
              previewAt: previewAt,
              onRate: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('10m'), findsNWidgets(Rating.values.length));
    });

    testWidgets('RatingBar shows all four ratings and reports taps', (
      tester,
    ) async {
      Rating? tapped;
      final now = DateTime.now().toUtc();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
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
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
      );

      expect(find.byKey(const Key('recall_queue_strip')), findsOneWidget);
      expect(find.byKey(const Key('recall_study_card')), findsOneWidget);
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
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
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

    testWidgets('native rating controls stay clear of the iOS tab bar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      final prefs = RecallPrefsController(api: api);
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: AppShell(
            controller: controller,
            api: api,
            prefs: prefs,
            linkSource: _SilentLinkSource(),
            nativeIos: true,
          ),
        ),
      );
      final canvas = tester.widget<ColoredBox>(
        find.byKey(const Key('recall_flat_canvas')),
      );
      expect(canvas.color, UiColors.canvas);
      await tester.tap(find.text('Show answer'));
      await tester.pump();

      final ratingBottom = tester.getRect(find.byType(RatingBar)).bottom;
      final tabBarTop = tester.getRect(find.byType(CupertinoTabBar)).top;
      expect(tabBarTop - ratingBottom, greaterThanOrEqualTo(UiSpacing.sm));
      expect(tester.takeException(), isNull);
    });
  });

  group('Decks screen', () {
    testWidgets('renders decks as flat ruled rows with explicit counts', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = _FakeRecallApi([_card()])
        ..deckCounts = const {1: (due: 3, neu: 2)};
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
            body: DecksScreen(
              controller: controller,
              api: api,
              onStudyDeck: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('recall_deck_row_All decks')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recall_deck_row_Portuguese')),
        findsOneWidget,
      );
      expect(find.text('3 due'), findsNWidgets(2));
      expect(find.text('2 new'), findsNWidgets(2));
      final row = tester.widget<Container>(
        find.byKey(const Key('recall_deck_row_Portuguese')),
      );
      final decoration = row.decoration! as BoxDecoration;
      expect(decoration.color, isNull);
      expect(decoration.border, isA<Border>());
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
      expect(
        find.byKey(const Key('recall_stats_session_strip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recall_stats_history_strip')),
        findsOneWidget,
      );
      expect(find.byType(ReviewHeatmap), findsOneWidget);
      expect(find.text('Could not load forecast.'), findsOneWidget);
    });
  });

  group('Read tab', () {
    const node = ConceptNodeInfo(
      nodeId: 'm00-vector-geometry',
      title: 'Vector geometry',
      module: 'M00',
    );

    Future<void> pumpShell(WidgetTester tester, _FakeRecallApi api) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      final prefs = RecallPrefsController(api: api);
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: AppShell(
            controller: controller,
            api: api,
            prefs: prefs,
            linkSource: _SilentLinkSource(),
            nativeIos: false,
          ),
        ),
      );
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows a primer reviewed today above the grouped library', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final api = _FakeRecallApi([_card()])
        ..reviewLog = [
          ReviewLogEntry(guid: 'g1', at: DateTime.now(), rating: 3),
        ]
        ..noteTags = const {'g1': 'node::m00-vector-geometry'}
        ..conceptNodes = const [node]
        ..conceptPages = [page];

      await pumpShell(tester, api);

      expect(find.byType(ReadScreen), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Vector geometry primer'), findsNWidgets(2));
      expect(find.text('M00'), findsOneWidget);
      expect(
        find.text('Nothing studied yet today — the library is below.'),
        findsNothing,
      );
    });

    testWidgets('shows the empty-today line while keeping the library', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final api = _FakeRecallApi([_card()])
        ..reviewLog = [
          ReviewLogEntry(
            guid: 'g1',
            at: DateTime.now().subtract(const Duration(days: 1)),
            rating: 3,
          ),
        ]
        ..noteTags = const {'g1': 'node::m00-vector-geometry'}
        ..conceptNodes = const [node]
        ..conceptPages = [page];

      await pumpShell(tester, api);

      expect(
        find.text('Nothing studied yet today — the library is below.'),
        findsOneWidget,
      );
      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.text('M00'), findsOneWidget);
    });

    testWidgets('shows queued reread rows and clears one after reading', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime(2026, 7, 29),
      );
      final api = _FakeRecallApi(const [])
        ..conceptNodes = const [node]
        ..conceptPages = [page];
      final store = LocalReviewStore();
      await store.enqueueRemediation([node.nodeId]);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: ReadScreen(api: api, store: store),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reread: Vector geometry primer'), findsOneWidget);
      await tester.tap(find.text('Reread: Vector geometry primer'));
      await tester.pumpAndSettle();
      expect(find.byType(PrimerScreen), findsOneWidget);

      Navigator.of(tester.element(find.byType(PrimerScreen))).pop();
      await tester.pumpAndSettle();
      expect(await store.remediationQueue(), isEmpty);
    });

    testWidgets('does not reread a primer already attributed today', (
      tester,
    ) async {
      final page = ConceptPage(
        nodeId: node.nodeId,
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime(2026, 7, 29),
      );
      final api = _FakeRecallApi(const [])
        ..reviewLog = [
          ReviewLogEntry(guid: 'g1', at: DateTime.now(), rating: 3),
        ]
        ..noteTags = const {'g1': 'node::m00-vector-geometry'}
        ..conceptNodes = const [node]
        ..conceptPages = [page];
      final store = LocalReviewStore();
      await store.enqueueRemediation([node.nodeId]);

      await tester.pumpWidget(
        MaterialApp(
          home: ReadScreen(api: api, store: store),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reread: Vector geometry primer'), findsNothing);
      expect(find.text('Vector geometry primer'), findsNWidgets(2));
    });
  });

  group('Offline store', () {
    test(
      'corrupt review outbox fails closed instead of looking empty',
      () async {
        SharedPreferences.setMockInitialValues({
          'recall_outbox_v1': '{not valid json',
        });

        await expectLater(
          LocalReviewStore().outbox(),
          throwsA(isA<LocalOutboxCorruptException>()),
        );
      },
    );

    test('corrupt flag outbox fails closed instead of looking empty', () async {
      SharedPreferences.setMockInitialValues({'flag_outbox_v1': '[broken'});

      await expectLater(
        LocalReviewStore().flagOutbox(),
        throwsA(isA<LocalOutboxCorruptException>()),
      );
    });

    test('snapshot round-trips decks + queue', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final dueUpdatedAt = DateTime.utc(2026, 7, 13, 12, 30);
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        globalDueCount: 12,
        globalDueUpdatedAt: dueUpdatedAt,
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
      expect(snap.globalDueCount, 12);
      expect(snap.globalDueUpdatedAt, dueUpdatedAt);
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

    test('event ids are unique and share one stable install id', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();

      final ids = [for (var i = 0; i < 200; i++) await store.newEventId()];

      expect(ids.toSet(), hasLength(200));
      final install = await store.installId();
      expect(install, isNotEmpty);
      expect(ids.every((id) => id.startsWith('$install-')), isTrue);
      // The random suffix must actually vary — a platform where the entropy
      // collapsed (web's 32-bit shifts) would still pass a uniqueness check on
      // the counter alone, so assert the tails differ too.
      final tails = {for (final id in ids) id.split('-').last};
      expect(tails.length, greaterThan(190));
    });

    test('a second store on the same install reuses its id', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await LocalReviewStore().installId();
      // A fresh instance (app restart) must not mint a new identity.
      expect(await LocalReviewStore().installId(), first);
    });

    test('the install id survives sign-out', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final before = await store.installId();

      await store.clear();

      // It identifies the device, not the user: reviews still queued from a
      // previous session keep their uniqueness guarantee.
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(LocalReviewStore.installIdKey), before);
      expect(await LocalReviewStore().installId(), before);
    });

    test('clear() drops snapshot + outbox (sign-out)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      await store.saveSnapshot(
        decks: const [DeckRow(deckId: 1, name: 'ML')],
        queue: [_card(id: 1)],
      );
      await store.enqueueReview({'card_id': 1, 'rating': 3});
      await store.enqueueFlag({'card_id': 1, 'reason': 'wrong'});
      await store.clear();
      expect(await store.loadSnapshot(), isNull);
      expect(await store.outbox(), isEmpty);
      expect(await store.flagOutbox(), isEmpty);
    });

    test('flag outbox enqueues, reads, and drains independently', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      // A flag write and a review write share the lock but stay separate lists.
      expect(await store.enqueueReview({'card_id': 1, 'rating': 3}), 1);
      expect(await store.enqueueFlag({'card_id': 1, 'reason': 'wrong'}), 1);
      expect(await store.enqueueFlag({'card_id': 2, 'reason': 'too_long'}), 2);
      expect((await store.flagOutbox()).length, 2);
      expect((await store.outbox()).length, 1); // review list untouched

      // Drain only the delivered prefix; a flag queued mid-flush survives.
      expect(await store.removeFirstFlag(1), 1);
      final left = await store.flagOutbox();
      expect(left.single['card_id'], 2);
      expect(left.single['reason'], 'too_long');
      // removeFirstFlag(0) is a pure count read; the review outbox is intact.
      expect(await store.removeFirstFlag(0), 1);
      expect((await store.outbox()).single['card_id'], 1);
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
      api.recallPrefsRow = {'new_limit_default': 7, 'desired_retention': 0.85};
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
        'per_deck': {
          '2': {'new_limit': 7},
        },
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

    test(
      'rate stamps elapsed_ms from card display to the rating tap',
      () async {
        final api = _FakeRecallApi([_card(id: 1)]);
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

    test(
      'an offline review carries the elapsed measured at review time',
      () async {
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
      },
    );
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

    test(
      'undo of an unflushed review is pure local and empties the outbox',
      () async {
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
      },
    );

    test(
      'undo of a flushed review restores the card and deletes the log row',
      () async {
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
      },
    );

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

    test(
      'undo waits out an in-flight flush and deletes the row it produced',
      () async {
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
      },
    );

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

    test(
      'undo never removes a persisted review with a colliding client_id',
      () async {
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
      },
    );

    test(
      'the flush hook ignores a delivered stale entry with a colliding id',
      () async {
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
      },
    );

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

  group('ReviewController flag', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    ReviewController build(
      _FakeRecallApi api, {
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
        final api = _FakeRecallApi([_card(id: 7)]);
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
      final api = _FakeRecallApi([_card(id: 1)]);
      final store = LocalReviewStore();
      final controller = build(api, store: store);
      await controller.load();
      await controller.flag('bogus');
      expect(await store.flagOutbox(), isEmpty);
    });

    test('flag is a no-op with no current card', () async {
      final api = _FakeRecallApi(const []);
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
        final api = _FakeRecallApi([_card(id: 1), _card(id: 2)]);
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

    test('a successful flag flush drains the flag outbox', () async {
      final api = _FakeRecallApi([_card(id: 1)]);
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

    test('queued flags survive a store reload (simulated restart)', () async {
      final api1 = _FakeRecallApi([_card(id: 3)]);
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
      final api2 = _FakeRecallApi([_card(id: 3)]);
      final store2 = LocalReviewStore();
      final c2 = build(api2, store: store2);
      await c2.load();
      await c2.syncPending();

      expect(api2.flagged.length, 1);
      expect(api2.flagged.single['reason'], 'duplicate');
      expect(await store2.flagOutbox(), isEmpty);
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
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
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
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(body: StudyScreen(controller: controller)),
        ),
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

  group('Flag UI', () {
    testWidgets('native iOS presents flag reasons as an action sheet', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReviewController(
        api: _FakeRecallApi([_card(id: 700)]),
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

      await tester.tap(find.byTooltip('Flag card'));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Wrong'), findsOneWidget);
    });

    testWidgets('flagging a card from the sheet enqueues and confirms', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final api = _FakeRecallApi([
        _card(id: 701, front: 'a question', back: 'an answer'),
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
      await tester.tap(find.byTooltip('Flag card'));
      await tester.pumpAndSettle();
      expect(find.text('Wrong'), findsOneWidget);
      expect(find.text('Confusing'), findsOneWidget);
      expect(find.text('Too long'), findsOneWidget);
      expect(find.text('Duplicate'), findsOneWidget);

      await tester.tap(find.text('Confusing'));
      await tester.pumpAndSettle();

      // Sheet dismissed, confirmation shown, flag queued, review untouched.
      expect(find.text('Confusing'), findsNothing);
      expect(find.text('Card flagged'), findsOneWidget);
      final flags = await store.flagOutbox();
      expect(flags.single['reason'], 'confusing');
      expect(flags.single['card_id'], 701);
      expect(controller.state.index, 0);
      expect(controller.state.showBack, isFalse);
    });

    testWidgets('cancelling the flag sheet enqueues nothing', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: _FakeRecallApi([_card(id: 702)]),
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
      await tester.tap(find.byTooltip('Flag card'));
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
      // confirmation — so "Card flagged" must never appear before the
      // SharedPreferences write has completed. Gate the store's enqueue and
      // assert the sheet stays up (no confirmation) until it lands.
      SharedPreferences.setMockInitialValues({});
      final store = _GatedFlagStore();
      final api = _FakeRecallApi([_card(id: 703)]);
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
      await tester.tap(find.byTooltip('Flag card'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Wrong'));
      await tester.pump();
      await tester.pump();
      // Enqueue still in flight: no confirmation, sheet still open.
      expect(find.text('Card flagged'), findsNothing);
      expect(find.text('Wrong'), findsOneWidget);

      store.enqueueGate.complete();
      await tester.pumpAndSettle();

      // Now — and only now — dismissed and confirmed, with the flag queued.
      expect(find.text('Wrong'), findsNothing);
      expect(find.text('Card flagged'), findsOneWidget);
      expect((await store.flagOutbox()).single['card_id'], 703);
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
        globalDueCount: globalDueCount,
        globalDueUpdatedAt: globalDueUpdatedAt,
        canWrite: canWrite,
      );
    } finally {
      saveFinished.complete();
    }
  }
}

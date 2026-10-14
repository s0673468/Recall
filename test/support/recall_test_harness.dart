// Shared fakes and fixtures for the recall_*_test.dart suites, moved out of
// the former test/recall_test.dart. All data here is synthetic.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthState, SupabaseClient, User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/data/review_replay.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/navigation/recall_deep_links.dart';

const desktopFsrsParameters = [
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

ReviewCard testCard({
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
  bool contentRevalidationPending = false,
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
  contentRevalidationPending: contentRevalidationPending,
);

/// One row of the modelled `cards` table — the mutable server-side scheduling
/// state a replay merges into.
class FakeServerCard {
  double? stability;
  double? difficulty;
  DateTime? due;
  int state;
  int reps;
  int lapses;
  DateTime? lastReview;
  bool cloudSeen;

  FakeServerCard({
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.state,
    required this.reps,
    required this.lapses,
    required this.lastReview,
    required this.cloudSeen,
  });

  factory FakeServerCard.from(ReviewCard c) => FakeServerCard(
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
/// to several [FakeRecallApi]s to model a multi-device collection.
class FakeServer {
  final Map<int, FakeServerCard> cards = {};
  final List<Map<String, dynamic>> reviewLog = [];

  /// Matches the previous recorder's numbering so existing undo tests keep
  /// asserting the same review_log ids.
  int nextLogId = 900;

  /// Awaited inside the guarded card update — lets a test interleave another
  /// device's write and force the compare-and-swap to lose.
  Future<void> Function()? beforeCardUpdate;

  void seed(ReviewCard card) =>
      cards.putIfAbsent(card.id, () => FakeServerCard.from(card));

  int? findLogByEventId(int cardId, String clientEventId) {
    for (final row in reviewLog) {
      if (row['card_id'] == cardId && row['client_event_id'] == clientEventId) {
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

class FakeRecallApi implements RecallApi {
  final List<ReviewCard> queue;
  final FsrsSettings? fsrsSettings;
  final List<DeckRow> decks;

  /// The server this device syncs against. Two fakes sharing one instance is
  /// how a two-device conflict is expressed.
  final FakeServer server;

  /// Overridable so two devices in one test are distinguishable in the log.
  final String deviceLabel;

  User? user;
  Map<int, ({int due, int neu})> deckCounts = const {};
  bool failDeckCounts = false;
  Object? signInError;
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
  Set<int>? lastIncludedDeckIds;

  FakeRecallApi(
    this.queue, {
    this.fsrsSettings,
    this.decks = const [DeckRow(deckId: 1, name: 'ML')],
    FakeServer? server,
    this.deviceLabel = 'test',
  }) : server = server ?? FakeServer() {
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
      contentRevalidationPending: template.contentRevalidationPending,
    );
  }

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();

  @override
  Future<List<DeckRow>> fetchDecks() async => decks;

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    queueFetches++;
    lastNewLimit = newLimit;
    lastOrder = order;
    lastIncludedDeckIds = includedDeckIds;
    lastExcludedCardIds = excludeCardIds;
    await beforeQueue?.call();
    return [
      for (final c in queue)
        if ((deckId == null || c.deckId == deckId) &&
            (includedDeckIds == null || includedDeckIds.contains(c.deckId)) &&
            !excludeCardIds.contains(c.id))
          _project(c),
    ];
  }

  @override
  Future<List<ReviewCard>> fetchContentRevalidationQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int limit = RecallApi.contentRevalidationBatchSize,
    Set<int> excludeCardIds = const {},
  }) async => [
    for (final card in queue)
      if (card.contentRevalidationPending &&
          !excludeCardIds.contains(card.id) &&
          (deckId == null || card.deckId == deckId) &&
          (includedDeckIds == null || includedDeckIds.contains(card.deckId)))
        _project(card),
  ].take(limit).toList();

  /// How many bonus batches were fetched, mirroring [queueFetches].
  int aheadFetches = 0;

  /// Mirrors the production query shape: server-projected cards due within
  /// the horizon (soonest first), topped up with unseen new cards.
  @override
  Future<List<ReviewCard>> fetchAheadQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    Duration horizon = const Duration(hours: 24),
    int limit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    aheadFetches++;
    lastAheadExcludedCardIds = excludeCardIds;
    final cutoff = DateTime.now().toUtc().add(horizon);
    final all = [
      for (final c in queue)
        if ((deckId == null || c.deckId == deckId) &&
            (includedDeckIds == null || includedDeckIds.contains(c.deckId)))
          _project(c),
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
  Future<FsrsSettings> applyFsrsOptimizerResult(
    Object result, {
    bool approved = false,
    String? confirmation,
    DateTime? appliedAt,
  }) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async => recallPrefsRow;

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async =>
      savedRecallPrefs.add(value);

  /// Every restore entry undoReview received, in order.
  final List<Map<String, dynamic>> undone = [];
  bool commitThenThrowReview = false;
  bool signedOut = false;

  /// Mirrors `RecallApi.applyReview` step for step: suppress a duplicate off
  /// the log's uniqueness constraint, merge through the *production* replay
  /// algorithm, then append the log row. Only the transport is fake.
  @override
  Future<int?> applyReview(Map<String, dynamic> e) async {
    await beforeApplyReview?.call();
    if (failApplyReview) throw StateError('review sync failed');
    final cardId = (e['card_id'] as num).toInt();
    final eventId = e['client_id']?.toString();
    final existing = eventId != null
        ? server.findLogByEventId(cardId, eventId)
        : server.findLogLegacy(cardId, e['last_review'], e['device']);
    if (existing != null) return existing;

    await applyMergedReview(this, e);
    if (failLogInsert) throw StateError('review_log insert failed');
    applied.add(e);
    final receipt = server.appendLog(e, clientEventId: eventId);
    if (commitThenThrowReview) throw StateError('reply lost after commit');
    return receipt;
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

  /// When true, a review stays queued so load() must filter it from the
  /// presentation queue even though the fake server still returns the card.
  bool failApplyReview = false;

  /// Awaited inside applyFlag — lets tests hold the flag flush open.
  Future<void> Function()? beforeApplyFlag;

  @override
  Future<void> applyFlag(Map<String, dynamic> e) async {
    await beforeApplyFlag?.call();
    if (failApplyFlag) throw StateError('note_flags missing');
    flagged.add(e);
    if (commitThenThrowFlag) throw StateError('reply lost');
  }

  /// The hidden ids the last forecast read excluded.
  Set<int> lastDueDateExcludedIds = const {};

  /// Client event ids of flags withdrawn through [dismissFlag].
  final List<String> dismissedFlags = [];

  /// The hidden ids the last queue and bonus fetches excluded.
  Set<int> lastExcludedCardIds = const {};
  Set<int> lastAheadExcludedCardIds = const {};

  /// Runs while a hidden-card read is in flight. The read still answers
  /// with the server state from when it started.
  Future<void> Function()? onFetchHidden;

  /// When true, applyFlag commits the flag and then throws, as if the reply
  /// was lost.
  bool commitThenThrowFlag = false;

  /// When true, the hidden-card read throws (e.g. offline).
  bool failFetchHidden = false;

  /// When true, dismissing a synced flag throws (offline undo).
  bool failDismissFlag = false;

  @override
  Future<Set<int>> fetchHiddenCardIds() async {
    if (failFetchHidden) throw StateError('offline');
    final committed = [...flagged];
    final dismissed = {...dismissedFlags};
    await onFetchHidden?.call();
    return {
      for (final flag in committed)
        if ((flag['reason'] == 'dislike' || flag['reason'] == 'delete') &&
            !dismissed.contains(flag['client_id']))
          (flag['card_id'] as num).toInt(),
    };
  }

  /// Awaited inside dismissFlag — lets tests hold a withdrawal open.
  Future<void> Function()? beforeDismissFlag;

  @override
  Future<void> dismissFlag({
    required int cardId,
    required String clientEventId,
  }) async {
    await beforeDismissFlag?.call();
    if (failDismissFlag) throw StateError('offline');
    dismissedFlags.add(clientEventId);
  }

  @override
  Future<void> undoReview(Map<String, dynamic> e) async {
    undone.add(e);
    throw const UndoConflictException();
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
    'guid': card.guid,
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
  List<({int deckId, DateTime due})>? scheduledDueDates;
  Set<int>? lastDueDateDeckIds;
  Map<String, String> noteTags = const {};
  List<ConceptNodeInfo> conceptNodes = const [];
  List<ConceptPage> conceptPages = const [];
  bool failReviewLog = false;
  bool failDueDates = false;

  /// The `days` window of every review-log read, in call order.
  final List<int> reviewLogReads = [];
  int conceptPageReads = 0;

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    reviewLogReads.add(days);
    if (failReviewLog) throw StateError('review_log fetch failed');
    return reviewLog;
  }

  @override
  Future<List<DateTime>> fetchDueDates({
    Set<int>? includedDeckIds,
    Set<int> excludeCardIds = const {},
  }) async {
    if (failDueDates) throw StateError('cards fetch failed');
    lastDueDateDeckIds = includedDeckIds;
    lastDueDateExcludedIds = excludeCardIds;
    final scheduled = scheduledDueDates;
    if (scheduled != null) {
      return [
        for (final row in scheduled)
          if (includedDeckIds == null || includedDeckIds.contains(row.deckId))
            row.due,
      ];
    }
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
  Future<List<ConceptPage>> fetchConceptPages() async {
    conceptPageReads++;
    return conceptPages;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    final error = signInError;
    if (error != null) throw error;
  }

  @override
  Future<void> signOut() async => signedOut = true;
}

class GatedFsrsRecallApi extends FakeRecallApi {
  final StreamController<AuthState> authStates =
      StreamController<AuthState>.broadcast();
  final Completer<void> fsrsStarted = Completer<void>();
  final Completer<void> releaseFsrs = Completer<void>();

  GatedFsrsRecallApi(super.queue, {super.fsrsSettings});

  @override
  Stream<AuthState> get onAuthStateChange => authStates.stream;

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async {
    fsrsStarted.complete();
    await releaseFsrs.future;
    return fsrsSettings;
  }
}

class SilentLinkSource implements RecallLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get links => const Stream.empty();
}

Future<void> enqueuePendingReview({
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

User testUser(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: DateTime.utc(2026, 8, 23).toIso8601String(),
);

Future<void> loadVisualFonts() async {
  final outfit = FontLoader('Outfit')
    ..addFont(rootBundle.load('assets/fonts/Outfit-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Outfit-Medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Outfit-SemiBold.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Outfit-Bold.ttf'));
  final dmSans = FontLoader('DM Sans')
    ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/DMSans-Medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/DMSans-SemiBold.ttf'))
    ..addFont(rootBundle.load('assets/fonts/DMSans-Bold.ttf'));
  final readingSerif = FontLoader('Georgia')
    ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'));
  FontLoader katex(String family, List<String> files) {
    final loader = FontLoader(family);
    for (final file in files) {
      loader.addFont(
        rootBundle.load(
          'packages/flutter_math_fork/lib/katex_fonts/fonts/$file',
        ),
      );
    }
    return loader;
  }

  final mathFonts = [
    katex('KaTeX_Main', const [
      'KaTeX_Main-Regular.ttf',
      'KaTeX_Main-Italic.ttf',
      'KaTeX_Main-Bold.ttf',
      'KaTeX_Main-BoldItalic.ttf',
    ]),
    katex('KaTeX_Math', const [
      'KaTeX_Math-Italic.ttf',
      'KaTeX_Math-BoldItalic.ttf',
    ]),
    katex('KaTeX_AMS', const ['KaTeX_AMS-Regular.ttf']),
    for (var size = 1; size <= 4; size++)
      katex('KaTeX_Size$size', ['KaTeX_Size$size-Regular.ttf']),
  ];
  await Future.wait([
    outfit.load(),
    dmSans.load(),
    readingSerif.load(),
    for (final font in mathFonts) font.load(),
  ]);
}

Future<bool> captureVisual(WidgetTester tester, String name) async {
  final output = Platform.environment['RECALL_VISUAL_OUTPUT'];
  final scene = Platform.environment['RECALL_VISUAL_SCENE'];
  if (output == null || output.isEmpty || scene != name) return false;
  Directory(output).createSync(recursive: true);
  await expectLater(
    find.byKey(const Key('visual_benchmark_boundary')),
    matchesGoldenFile(Uri.file('$output/$name.png')),
  );
  debugDefaultTargetPlatformOverride = null;
  return true;
}

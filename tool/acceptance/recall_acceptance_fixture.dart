import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/app/recall_dependencies.dart';
import 'package:health_anki_flutter/core/background/background_sync_coordinator.dart';
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

enum AcceptanceScenario {
  rich,
  empty,
  offline,
  partialStatsFailure,
  signedOut;

  static AcceptanceScenario parse(String value) => switch (value) {
    'rich' => AcceptanceScenario.rich,
    'empty' => AcceptanceScenario.empty,
    'offline' => AcceptanceScenario.offline,
    'partial_stats_failure' => AcceptanceScenario.partialStatsFailure,
    'signed_out' => AcceptanceScenario.signedOut,
    _ => throw ArgumentError.value(value, 'value', 'unknown scenario'),
  };
}

class SanitizedRecallDataset {
  static const cardCount = 1600;
  static const reviewCount = 12000;
  static const conceptCount = 72;

  final DateTime now;
  final List<DeckRow> decks;
  final List<ReviewCard> cards;
  final List<ReviewLogEntry> reviews;
  final Map<String, String> noteTags;
  final List<ConceptNodeInfo> conceptNodes;
  final List<ConceptPage> conceptPages;

  const SanitizedRecallDataset({
    required this.now,
    required this.decks,
    required this.cards,
    required this.reviews,
    required this.noteTags,
    required this.conceptNodes,
    required this.conceptPages,
  });

  factory SanitizedRecallDataset.productionScale({DateTime? now}) {
    final anchor = (now ?? DateTime.now()).toUtc();
    final decks = <DeckRow>[
      for (var i = 0; i < 28; i++)
        DeckRow(deckId: i + 1, name: _automaticDeckName(i)),
      const DeckRow(deckId: 29, name: 'Portuguese'),
      const DeckRow(deckId: 30, name: 'Opt-in::Russian Revolution'),
      const DeckRow(deckId: 31, name: 'Experimental::Research curriculum'),
      const DeckRow(
        deckId: 32,
        name: 'Opt-in::Very long optional curriculum name for layout stress',
      ),
    ];
    final cards = <ReviewCard>[];
    final tags = <String, String>{};
    for (var i = 1; i <= cardCount; i++) {
      final deckId = ((i - 1) % decks.length) + 1;
      final isNew = i % 5 == 0;
      final due = isNew ? null : anchor.add(Duration(hours: (i % 120) - 84));
      final conceptId = 'concept-${(i % conceptCount) + 1}';
      final guid = 'sanitized-guid-$i';
      final content = _cardContent(i);
      tags[guid] = 'sanitized node::$conceptId ${i % 9 == 0 ? 'priority' : ''}';
      cards.add(
        ReviewCard(
          id: i,
          guid: guid,
          deckId: deckId,
          front: content.front,
          back: content.back,
          hasLatex: content.hasLatex,
          stability: isNew ? null : 2.5 + (i % 80) / 4,
          difficulty: isNew ? null : 3 + (i % 60) / 10,
          due: due,
          state: isNew ? 0 : (i % 17 == 0 ? 3 : 2),
          reps: isNew ? 0 : 2 + (i % 48),
          lapses: isNew ? 0 : i % 7,
          lastReview: isNew
              ? null
              : anchor.subtract(Duration(days: 1 + (i % 90))),
          cloudSeen: !isNew,
          tags: tags[guid],
          latexSvg: i == cardCount ? _fixtureSvg(i) : null,
          contentRevalidationPending: i % 97 == 0,
        ),
      );
    }

    final reviews = <ReviewLogEntry>[
      for (var i = 0; i < reviewCount; i++)
        () {
          final card = cards[(i * 37) % cards.length];
          final at = anchor.subtract(
            Duration(days: i % 190, hours: i % 19, minutes: i % 53),
          );
          final rating = i % 11 == 0 ? 1 : 2 + (i % 3);
          return ReviewLogEntry(
            cardId: card.id,
            guid: card.guid,
            at: at.toLocal(),
            rating: rating,
            stateAfter: rating == 1 && i % 4 == 0 ? 3 : 2,
            dueAfter: at.add(Duration(days: 1 + (i % 45))).toLocal(),
          );
        }(),
    ]..sort((a, b) => a.at.compareTo(b.at));

    final nodes = <ConceptNodeInfo>[
      for (var i = 1; i <= conceptCount; i++)
        ConceptNodeInfo(
          nodeId: 'concept-$i',
          title: 'Sanitized concept $i',
          module: 'Module ${((i - 1) ~/ 9) + 1}',
        ),
    ];
    final pages = <ConceptPage>[
      for (var i = 1; i <= conceptCount; i++)
        ConceptPage(
          nodeId: 'concept-$i',
          title: i == conceptCount
              ? 'Sanitized concept $i — a deliberately long primer title that '
                    'must wrap without clipping'
              : 'Sanitized concept $i',
          bodyHtml:
              '<strong>Core idea.</strong> This local primer explains concept $i '
              'with synthetic text only.<br><br>'
              'The governing relation is \\(y = wx + b\\), where every symbol is '
              'defined in this sanitized example.',
          figureSvg: i % 12 == 0 ? _fixtureSvg(i) : null,
          updatedAt: anchor.subtract(Duration(days: i % 30)),
        ),
    ];

    return SanitizedRecallDataset(
      now: anchor,
      decks: decks,
      cards: cards,
      reviews: reviews,
      noteTags: tags,
      conceptNodes: nodes,
      conceptPages: pages,
    );
  }

  static String _automaticDeckName(int index) {
    const roots = ['ML', 'Math', 'Physics', 'Statistics', 'Computer Science'];
    final root = roots[index % roots.length];
    return '$root::Module ${(index ~/ roots.length) + 1}';
  }

  static ({String front, String back, bool hasLatex}) _cardContent(int id) {
    if (id == cardCount - 1) {
      return (
        front:
            'This deliberately long synthetic prompt checks that a production-'
            'scale card can wrap, scroll, and keep its primary controls reachable '
            'without exposing any real learning material. ${'detail ' * 40}',
        back:
            '<strong>Long answer.</strong> ${'Sanitized explanation. ' * 40}'
            '<br><img src="missing-sanitized-media.png" '
            'alt="Synthetic missing-media example">',
        hasLatex: false,
      );
    }
    return switch (id % 6) {
      0 => (
        front: 'Why does a model overfit?',
        back:
            '<strong>It learns noise.</strong><br><br>The training signal contains '
            'patterns that do not generalize to new samples.',
        hasLatex: false,
      ),
      1 => (
        front: 'Interpret \\(y = wx + b\\) in one sentence.',
        back:
            'The weight \\(w\\) controls how input \\(x\\) changes the output, '
            'while \\(b\\) shifts the baseline.',
        hasLatex: true,
      ),
      2 => (
        front: 'A robust workflow has {{c1::one authority}} for mutable state.',
        back:
            'Caches may speed up reads, but pending writes need durable replay '
            'until the authority accepts them.',
        hasLatex: false,
      ),
      3 => (
        front:
            '<code>validation_loss</code> rises while training loss falls. Why?',
        back:
            '<ul><li>The model is fitting training-specific detail.</li>'
            '<li>Regularization or earlier stopping may help.</li></ul>',
        hasLatex: false,
      ),
      4 => (
        front:
            'What must remain true across offline review, reconnect, and retry?',
        back:
            '<strong>Exactly one logical review.</strong><br><br>A stable event id '
            'makes repeated delivery safe without losing the original action.',
        hasLatex: false,
      ),
      _ => (
        front: 'Explain the sign of a gradient update.',
        back:
            'Gradient descent moves opposite the gradient: '
            '\\(\\theta_{t+1}=\\theta_t-\\eta\\nabla L(\\theta_t)\\). '
            'The minus sign reduces the local loss when \\(\\eta>0\\).',
        hasLatex: true,
      ),
    };
  }

  static String _fixtureSvg(int id) =>
      '<svg viewBox="0 0 600 360" xmlns="http://www.w3.org/2000/svg">'
      '<rect width="600" height="360" rx="28" fill="#171b22"/>'
      '<path d="M80 280 C190 90 330 320 520 80" fill="none" '
      'stroke="#ff7f6e" stroke-width="18" stroke-linecap="round"/>'
      '<circle cx="${120 + id}" cy="200" r="28" fill="#71c5e8"/>'
      '</svg>';
}

class SanitizedRecallApi extends RecallApi {
  final SanitizedRecallDataset dataset;
  final AcceptanceScenario scenario;
  final StreamController<AuthState> _authStates =
      StreamController<AuthState>.broadcast();
  final Map<String, Set<int>> _reviewedCardIdsByOwner = {};
  final Map<String, List<int>> _appliedReviewCardIdsByOwner = {};
  final Map<String, List<Map<String, dynamic>>> _appliedFlagsByOwner = {};
  final Map<String, List<ReviewLogEntry>> _reviewsByOwner = {};
  final Map<String, Map<String, dynamic>> _prefsRowsByOwner = {};

  User? _user;
  bool online;
  int _nextReviewLogId = 20000;

  SanitizedRecallApi({required this.dataset, required this.scenario})
    : online = scenario != AcceptanceScenario.offline,
      super(
        SupabaseClient(
          'https://sanitized-recall.invalid',
          'sanitized-local-publishable-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      ) {
    if (scenario != AcceptanceScenario.signedOut) _user = _acceptanceUser();
  }

  bool get _empty => scenario == AcceptanceScenario.empty;

  List<int> get appliedReviewCardIds => List<int>.unmodifiable(
    _appliedReviewCardIdsByOwner[_requireOwnerId()] ?? const <int>[],
  );

  List<Map<String, dynamic>> get appliedFlags => List.unmodifiable(
    _appliedFlagsByOwner[_requireOwnerId()] ?? const <Map<String, dynamic>>[],
  );

  @override
  String get device => 'sanitized-local-web';

  @override
  User? get currentUser => _user;

  @override
  Stream<AuthState> get onAuthStateChange => _authStates.stream;

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (email.isEmpty || password.isEmpty) throw const AuthException('invalid');
    _user = _acceptanceUser(email: email);
    _authStates.add(const AuthState(AuthChangeEvent.signedIn, null));
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _authStates.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  @override
  Future<List<DeckRow>> fetchDecks() async {
    _requireOnline();
    return List<DeckRow>.unmodifiable(dataset.decks);
  }

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async => null;

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    _requireOnline();
    final row = _prefsRowsByOwner[_requireOwnerId()];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    _requireOnline();
    _prefsRowsByOwner[_requireOwnerId()] = Map<String, dynamic>.from(value);
  }

  Iterable<ReviewCard> _selected({int? deckId, Set<int>? includedDeckIds}) {
    if (_empty) return const <ReviewCard>[];
    final reviewedCardIds =
        _reviewedCardIdsByOwner[_requireOwnerId()] ?? const {};
    return dataset.cards.where((card) {
      if (reviewedCardIds.contains(card.id)) return false;
      if (deckId != null) return card.deckId == deckId;
      return includedDeckIds == null || includedDeckIds.contains(card.deckId);
    });
  }

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    _requireOnline();
    final cards = _selected(deckId: deckId, includedDeckIds: includedDeckIds);
    final revalidations = cards
        .where((card) => card.contentRevalidationPending)
        .take(RecallApi.contentRevalidationBatchSize)
        .toList();
    final revalidationIds = {for (final card in revalidations) card.id};
    final due =
        cards
            .where(
              (card) =>
                  !card.isNew &&
                  card.due != null &&
                  !card.due!.isAfter(dataset.now) &&
                  !revalidationIds.contains(card.id),
            )
            .toList()
          ..sort((a, b) => a.due!.compareTo(b.due!));
    final fresh = cards.where((card) => card.isNew).toList();
    switch (order) {
      case NewOrder.oldestFirst:
        fresh.sort((a, b) => a.id.compareTo(b.id));
      case NewOrder.newestFirst:
        fresh.sort((a, b) => b.id.compareTo(a.id));
      case NewOrder.random:
        fresh.sort(
          (a, b) => _stableShuffleKey(a.id).compareTo(_stableShuffleKey(b.id)),
        );
    }
    return [...revalidations, ...due, ...fresh.take(newLimit)];
  }

  @override
  Future<List<ReviewCard>> fetchContentRevalidationQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int limit = RecallApi.contentRevalidationBatchSize,
  }) async {
    _requireOnline();
    return _selected(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
    ).where((card) => card.contentRevalidationPending).take(limit).toList();
  }

  @override
  Future<List<ReviewCard>> fetchAheadQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    Duration horizon = const Duration(hours: 24),
    int limit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    _requireOnline();
    final cutoff = dataset.now.add(horizon);
    final cards = _selected(deckId: deckId, includedDeckIds: includedDeckIds);
    final scheduled =
        cards
            .where(
              (card) =>
                  !card.isNew &&
                  card.due != null &&
                  card.due!.isAfter(dataset.now) &&
                  !card.due!.isAfter(cutoff),
            )
            .toList()
          ..sort((a, b) => a.due!.compareTo(b.due!));
    final fresh = cards.where((card) => card.isNew).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return [...scheduled, ...fresh].take(limit).toList();
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    _requireOnline();
    final ownerId = _requireOwnerId();
    final cardId = (entry['card_id'] as num).toInt();
    _reviewedCardIdsByOwner.putIfAbsent(ownerId, () => <int>{}).add(cardId);
    _appliedReviewCardIdsByOwner
        .putIfAbsent(ownerId, () => <int>[])
        .add(cardId);
    _reviewsForOwner(ownerId).add(
      ReviewLogEntry(
        cardId: cardId,
        guid: entry['guid'] as String?,
        at: DateTime.parse(entry['last_review'] as String).toLocal(),
        rating: (entry['rating'] as num).toInt(),
        stateAfter: (entry['state'] as num?)?.toInt(),
        dueAfter: entry['due'] == null
            ? null
            : DateTime.parse(entry['due'] as String).toLocal(),
      ),
    );
    return ++_nextReviewLogId;
  }

  @override
  Future<void> undoReview(Map<String, dynamic> entry) async {
    _requireOnline();
    final ownerId = _requireOwnerId();
    final cardId = (entry['card_id'] as num).toInt();
    _reviewedCardIdsByOwner[ownerId]?.remove(cardId);
    final reviews = _reviewsForOwner(ownerId);
    for (var i = reviews.length - 1; i >= 0; i--) {
      if (reviews[i].cardId == cardId) {
        reviews.removeAt(i);
        break;
      }
    }
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    _requireOnline();
    _appliedFlagsByOwner
        .putIfAbsent(_requireOwnerId(), () => <Map<String, dynamic>>[])
        .add(Map<String, dynamic>.from(entry));
  }

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    _requireOnline();
    final cutoff = dataset.now.subtract(Duration(days: days));
    return _reviewsForOwner(
      _requireOwnerId(),
    ).where((review) => !review.at.toUtc().isBefore(cutoff)).toList();
  }

  @override
  Future<Map<String, String>> fetchNoteTags() async {
    _requireOnline();
    return Map<String, String>.unmodifiable(dataset.noteTags);
  }

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async {
    _requireOnline();
    return List<ConceptNodeInfo>.unmodifiable(dataset.conceptNodes);
  }

  @override
  Future<List<ConceptPage>> fetchConceptPages() async {
    _requireOnline();
    return List<ConceptPage>.unmodifiable(dataset.conceptPages);
  }

  @override
  Future<List<DateTime>> fetchDueDates({Set<int>? includedDeckIds}) async {
    _requireOnline();
    if (scenario == AcceptanceScenario.partialStatsFailure) {
      throw StateError('sanitized forecast failure');
    }
    return _selected(includedDeckIds: includedDeckIds)
        .where((card) => !card.isNew && card.due != null)
        .map((card) => card.due!.toLocal())
        .toList();
  }

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async {
    _requireOnline();
    final counts = <int, ({int due, int neu})>{};
    for (final deck in dataset.decks) {
      var due = 0;
      var fresh = 0;
      for (final card in _selected(deckId: deck.deckId)) {
        if (card.isNew) {
          fresh++;
        } else if (card.due != null && !card.due!.isAfter(dataset.now)) {
          due++;
        }
      }
      counts[deck.deckId] = (due: due, neu: fresh);
    }
    return counts;
  }

  void disposeFixture() {
    unawaited(_authStates.close());
    client.dispose();
  }

  void _requireOnline() {
    if (!online) throw StateError('sanitized offline scenario');
  }

  String _requireOwnerId() {
    final id = _user?.id;
    if (id == null) throw const AuthException('not authenticated');
    return id;
  }

  List<ReviewLogEntry> _reviewsForOwner(String ownerId) => _reviewsByOwner
      .putIfAbsent(ownerId, () => List<ReviewLogEntry>.from(dataset.reviews));

  static int _stableShuffleKey(int value) =>
      (value * 1103515245 + 12345) & 0x7fffffff;

  static User _acceptanceUser({String email = 'learner@example.invalid'}) {
    final normalizedEmail = email.trim().toLowerCase();
    final ownerSlug = normalizedEmail
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('^-|\$'), '');
    return User(
      id: 'sanitized-$ownerSlug',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      email: normalizedEmail,
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
  }
}

class AcceptanceReminderPlatform implements StudyReminderPlatform {
  bool permissionGranted;
  StudyReminderSettings? applied;

  AcceptanceReminderPlatform({this.permissionGranted = true});

  @override
  Future<void> apply(
    StudyReminderSettings settings, {
    required int? dueCount,
    required bool studiedToday,
  }) async {
    applied = settings;
  }

  @override
  Future<void> cancel() async => applied = null;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<bool> requestPermission() async => permissionGranted;
}

class AcceptanceBackgroundSyncPlatform implements BackgroundSyncPlatform {
  @override
  Future<void> start(Future<String> Function() onSyncRequested) async {}
}

Future<RecallDependencies> createSanitizedAcceptanceDependencies({
  required AcceptanceScenario scenario,
  DateTime? now,
  bool resetPreferences = true,
}) async {
  // This separate acceptance entrypoint must never hydrate or mutate ordinary
  // app preferences from the localhost origin.
  // ignore: invalid_use_of_visible_for_testing_member
  if (resetPreferences) SharedPreferences.setMockInitialValues({});
  final dataset = SanitizedRecallDataset.productionScale(now: now);
  final api = SanitizedRecallApi(dataset: dataset, scenario: scenario);
  final store = LocalReviewStore();
  final prefs = RecallPrefsController(api: api);
  final reminder = StudyReminderController(
    platform: AcceptanceReminderPlatform(),
    clock: () => dataset.now.toLocal(),
  );
  final ownerId = api.currentUser?.id;
  if (ownerId != null) {
    await store.activateOwner(ownerId);
    await prefs.activateOwner(ownerId);
    await reminder.initialize(ownerId: ownerId, apply: false);
  } else {
    await prefs.releaseOwner();
    await reminder.initialize(apply: false);
  }
  final engine = FsrsEngine(desiredRetention: RecallPrefs.defaultRetention);
  final controller = ReviewController(
    api: api,
    engine: engine,
    store: store,
    prefs: prefs,
    clock: () => dataset.now,
    beforeSessionLoad: () async {
      final owner = api.currentUser;
      if (owner != null) {
        await store.activateOwner(owner.id);
        await prefs.activateOwner(owner.id);
      }
    },
    afterSignIn: () async {
      final owner = api.currentUser;
      if (owner != null) await reminder.activateOwner(owner.id);
    },
    afterSignOut: () async {
      await reminder.releaseOwner();
      await prefs.releaseOwner();
      await store.releaseOwner();
    },
  );

  if (ownerId != null) {
    if (scenario == AcceptanceScenario.offline) {
      final automaticIds = automaticReviewDeckIds(dataset.decks);
      final snapshotQueue = dataset.cards
          .where(
            (card) =>
                automaticIds.contains(card.deckId) &&
                !card.isNew &&
                card.due != null &&
                !card.due!.isAfter(dataset.now),
          )
          .take(60)
          .toList();
      await store.saveSnapshot(
        decks: dataset.decks,
        queue: snapshotQueue,
        globalDueCount: snapshotQueue.length,
        globalDueUpdatedAt: dataset.now.subtract(const Duration(minutes: 8)),
      );
    }
    await controller.initialize();
  }

  final background = BackgroundSyncCoordinator(
    platform: AcceptanceBackgroundSyncPlatform(),
    sync: controller.syncPendingInBackground,
  );
  await background.start();
  return RecallDependencies(
    reviewController: controller,
    api: api,
    recallPrefs: prefs,
    backgroundSync: background,
    studyReminder: reminder,
  );
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, AuthState, User;

import '../../../core/background/background_sync_coordinator.dart';
import '../../../core/diagnostics/operational_diagnostics.dart';
import '../../settings/application/recall_prefs_controller.dart';
import '../../settings/domain/recall_prefs.dart';
import '../data/catch_up_state.dart';
import '../data/local_review_preferences.dart';
import '../data/local_review_store.dart';
import '../data/models.dart';
import '../data/recall_api.dart';
import '../data/recall_read_cache.dart';
import '../domain/concept_attribution.dart';
import '../domain/stats_models.dart';
import 'backlog_catch_up.dart';
import 'fsrs_engine.dart';
import 'review_haptics.dart';
import 'review_state.dart';

typedef ReviewActivitySnapshot = ({bool available, DateTime? latest});
typedef _RecentReviews = ({
  List<ReviewLogEntry> reviews,
  ReviewActivitySnapshot activity,
});

/// A rating or flag whose native write threw with unknown commit status and
/// that native truth then showed absent. Like a refused save, nothing was
/// stored or sent, and the user has been told.
class StudyActionNotSavedException implements Exception {
  final Object cause;
  const StudyActionNotSavedException(this.cause);

  @override
  String toString() => 'Recall could not save the study action ($cause).';
}

/// A rating or flag whose native write threw and whose follow-up native read
/// failed too, so it may or may not be stored. The user has been told.
class StudyActionUnconfirmedException implements Exception {
  final Object cause;
  const StudyActionUnconfirmedException(this.cause);

  @override
  String toString() => 'Recall could not confirm the study action ($cause).';
}

class _SignOutAttempt {
  final int sessionGeneration;
  late final Future<void> task;
  Future<void>? signedOutRelease;

  _SignOutAttempt(this.sessionGeneration);
}

/// Owns auth + the study session: gates on the signed-in user, loads the queue
/// (cloud, with an offline cache fallback), flips cards, schedules ratings with
/// FSRS, and persists each review through a durable outbox so a review done
/// offline is never lost.
///
/// Latency contract (the iPhone PWA lives or dies by this):
///  - a cold open paints the cached snapshot immediately and refreshes from
///    the network in the background;
///  - rating a card never waits on the network — the outbox flush runs behind
///    the already-advanced UI.
///
/// Also owns two per-review niceties:
///  - time-on-card: a wall-clock stopwatch starts when a card's front becomes
///    visible and stops at the rating tap (revealing the answer does not
///    reset it), stamped into the review as `elapsed_ms`;
///  - single-level undo: the most recent rating can be reverted until the
///    next rating lands or the queue is reloaded (see [undo]).
class ReviewController extends ChangeNotifier {
  /// Shown in the study header when device storage refused a rating or flag,
  /// or a thrown write left nothing in native truth. Nothing was saved, so
  /// the card stays on screen for a redo.
  static const saveRefusedNotice = "Couldn't save that — try again.";

  /// Shown when a thrown write could not be checked against native truth.
  /// It may be stored, so a redo of the same rating reuses its id.
  static const saveUnconfirmedNotice =
      "Couldn't confirm that save — try again.";

  final RecallApi api;
  final FsrsEngine engine;
  final LocalReviewStore store;
  final ReviewHaptics haptics;
  final OperationalEventRecorder diagnostics;

  /// Wall clock, injectable so tests can drive the elapsed-time stopwatch.
  final DateTime Function() clock;

  /// Study preferences (new-card limit, retention, ordering). Optional so the
  /// existing test harness can construct the controller without one.
  final RecallPrefsController? prefs;
  final Future<void> Function()? beforeSessionLoad;
  final Future<void> Function()? afterSignOut;
  final Future<void> Function()? afterSignIn;
  StreamSubscription<AuthState>? _authSub;
  String? _activeUserId;
  String? _sessionSetupOwner;
  Future<void>? _sessionSetupTask;
  int _sessionSetupGeneration = 0;
  Future<void>? _signedOutReleaseTask;

  ReviewController({
    required this.api,
    required this.engine,
    required this.store,
    this.prefs,
    this.beforeSessionLoad,
    this.afterSignOut,
    this.afterSignIn,
    ReviewHaptics? haptics,
    OperationalEventRecorder? diagnostics,
    DateTime Function()? clock,
  }) : haptics = haptics ?? ReviewHaptics.forPlatform(),
       diagnostics = diagnostics ?? RecallDiagnostics.instance,
       clock = clock ?? DateTime.now {
    // Supabase emits auth errors (e.g. an offline token refresh) as STREAM
    // errors; without onError they rethrow and can crash the app. Swallow them —
    // an active session going offline should fall back to the cache, not die.
    _authSub = api.onAuthStateChange.listen(
      _onAuthChanged,
      onError: (Object _) {
        unawaited(
          this.diagnostics.record(
            level: OperationalLevel.error,
            component: OperationalComponent.auth,
            operation: OperationalOperation.observeAuthState,
            outcome: OperationalOutcome.failed,
            causeCode: OperationalCauseCode.authStreamError,
            retryable: true,
          ),
        );
      },
    );
    prefs?.addListener(_onPrefsChanged);
  }

  RecallPrefs get _activePrefs => prefs?.value ?? const RecallPrefs();
  RecallPrefs? _appliedPrefs;

  /// React to a settings change: keep the engine's retention in lockstep and
  /// reload the queue when a queue-shaping field (limit/order/per-deck) moved.
  void _onPrefsChanged() {
    final p = prefs;
    if (p == null) return;
    final next = p.value;
    final prev = _appliedPrefs;
    _appliedPrefs = next;

    engine.setDesiredRetention(next.desiredRetention);
    _previewForCardId = null; // rating-button intervals must re-price
    _previewAt = null;

    // Only reload once a session-driven load has happened. On the initial
    // startup hydration (prefs.load() before any queue load) the auth-driven
    // load() reads prefs.value directly, so a reload here would be premature.
    final queueAffecting = prev == null || !prev.sameQueueShape(next);
    // An open website periodically receives settings from other devices.
    // Keep a revealed/in-progress card, its timer and undo state in place;
    // the next explicit or idle refresh reads the new queue preferences.
    final preserveActiveCard = p.applyingCloudUpdate && _state.current != null;
    if (queueAffecting && _sessionLoaded && !preserveActiveCard) {
      unawaited(refresh());
    } else {
      notifyListeners();
    }
  }

  ReviewState _state = const ReviewState(loading: false);
  ReviewState get state => _state;

  User? get currentUser => api.currentUser;

  /// Changes whenever a same-day local remediation item is enqueued. UI
  /// surfaces use this to refresh their disposable queue after a rating.
  int _remediationRevision = 0;
  int get remediationRevision => _remediationRevision;

  void _set(ReviewState next) {
    // Every state transition funnels through here, so this is the one spot
    // that can reliably notice "a different card's front is now on screen"
    // and restart the elapsed-time stopwatch. Metadata-only updates (sync
    // badge ticks, flips) keep the same current card and leave it running.
    final current = next.current;
    if (current?.id != _timedCardId) {
      _timedCardId = current?.id;
      _cardShownAt = current == null ? null : clock();
    }
    _state = next;
    notifyListeners();
  }

  // --- Auth ---

  void _onAuthChanged(AuthState change) {
    final user = api.currentUser;
    if (user == null || change.event == AuthChangeEvent.signedOut) {
      // Signed out — drop the session state and show the login gate.
      RecallReadCache.of(api).clear();
      final signOutAttempt = _signOutAttempt;
      final signedOutGeneration = _sessionSetupGeneration;
      _sessionSetupGeneration++;
      _activeUserId = null;
      _sessionSetupOwner = null;
      _sessionLoaded = false;
      final release = _releaseAfterAuthSignOut();
      if (signOutAttempt?.sessionGeneration == signedOutGeneration) {
        signOutAttempt!.signedOutRelease = release;
      }
      unawaited(release);
      _invalidateActiveSession();
      engine.resetToDefaults();
      _undo = null; // the session (and its undo snapshot) is gone
      _hideUndo = null;
      _set(const ReviewState(loading: false));
      // Auth events can be queued: a new login may already be current when
      // the old signedOut event is delivered. It is still a new session even
      // when that login has the same UID.
      if (user != null) {
        _activeUserId = user.id;
        _startSignedInSession(user.id);
      }
    } else {
      // A provider can switch accounts without emitting an intermediate local
      // sign-out. Do not let the old queue, due count, or review activity drive
      // the new owner's reminder while that owner's data is loading.
      final newSession =
          change.event == AuthChangeEvent.signedIn && _activeUserId == user.id;
      if (_activeUserId != user.id || newSession) {
        // Shared Stats/Read aggregates belong to the previous owner.
        RecallReadCache.of(api).clear();
        _sessionSetupGeneration++;
        if (_activeUserId != null) {
          _sessionLoaded = false;
          _sessionSetupOwner = null;
          _invalidateActiveSession();
          engine.resetToDefaults();
          _set(const ReviewState(loading: false));
        }
      }
      _activeUserId = user.id;
      _startSignedInSession(user.id);
    }
  }

  void _startSignedInSession(String ownerId) {
    if (_sessionSetupOwner == ownerId && _sessionSetupTask != null) return;
    final generation = _sessionSetupGeneration;
    late final Future<void> task;
    task = _prepareSignedInSession(ownerId, generation).whenComplete(() {
      if (identical(_sessionSetupTask, task)) {
        _sessionSetupTask = null;
        _sessionSetupOwner = null;
      }
    });
    _sessionSetupOwner = ownerId;
    _sessionSetupTask = task;
    unawaited(task);
  }

  Future<void> _prepareSignedInSession(String ownerId, int generation) async {
    // Supabase can emit a new signed-in session while the previous account's
    // native reminder and local preference cleanup is still running. Never
    // activate the new owner until that account-scoped release has completed,
    // otherwise the old cleanup could clear the new owner's state.
    final signedOutRelease = _signedOutReleaseTask;
    if (signedOutRelease != null) {
      await signedOutRelease;
      if (identical(_signedOutReleaseTask, signedOutRelease)) {
        _signedOutReleaseTask = null;
      }
    }
    if (api.currentUser?.id != ownerId ||
        _sessionSetupGeneration != generation) {
      return;
    }

    try {
      // Account-scoped local preferences are a queue input. Wait for that local
      // read, but let their cloud replay/refresh run independently so a slow or
      // offline network can never hold the study shell on startup.
      await beforeSessionLoad?.call();
    } catch (_) {
      if (api.currentUser?.id == ownerId &&
          _sessionSetupGeneration == generation) {
        _set(
          _state.copyWith(
            loading: false,
            authSubmitting: false,
            error: 'Recall could not prepare this account. Try again.',
          ),
        );
      }
      return;
    }
    if (api.currentUser?.id != ownerId ||
        _sessionSetupGeneration != generation) {
      return;
    }

    unawaited(_afterSignIn());
    if (_state.queue.isEmpty && !_state.loading) {
      await _loadSafely();
    } else {
      notifyListeners();
    }
  }

  Future<void> _afterSignIn() async {
    try {
      await afterSignIn?.call();
    } catch (_) {
      debugPrint('Recall: reminder re-arm failed (non-fatal)');
    }
  }

  Future<void> _releaseAfterAuthSignOut() {
    final existing = _signedOutReleaseTask;
    if (existing != null) return existing;
    final task = _runSignedOutRelease();
    _signedOutReleaseTask = task;
    return task;
  }

  Future<void> _runSignedOutRelease() async {
    try {
      final callback = afterSignOut;
      if (callback != null) {
        await callback();
      } else {
        await prefs?.releaseOwner();
      }
    } catch (_) {
      debugPrint('Recall: signed-out resource release failed (non-fatal)');
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    _set(_state.copyWith(authSubmitting: true, error: null));
    try {
      await api.signIn(email: email, password: password);
      // _onAuthChanged fires on success and loads the queue.
    } catch (e) {
      _set(_state.copyWith(authSubmitting: false, error: _authMessage(e)));
    }
  }

  _SignOutAttempt? _signOutAttempt;
  final Map<Future<void>, int> _studyActionTasks = {};

  /// Admit before the first producer await so sign-out can close ingress and
  /// join every action that could still append a review, flag, or withdrawal.
  Future<void> _runStudyAction(Future<void> Function() action) {
    if (_signOutAttempt?.sessionGeneration == _sessionSetupGeneration) {
      return Future.value();
    }
    final sessionGeneration = _sessionSetupGeneration;
    final completion = Completer<void>();
    late final Future<void> task;
    task = completion.future.whenComplete(() => _studyActionTasks.remove(task));
    _studyActionTasks[task] = sessionGeneration;
    // A body's synchronous notification can itself initiate sign-out. Record
    // admission before invoking it, including before that first notification.
    action().then(completion.complete, onError: completion.completeError);
    return task;
  }

  Future<void> signOut() {
    final existing = _signOutAttempt;
    if (existing?.sessionGeneration == _sessionSetupGeneration) {
      return existing!.task;
    }
    // Install the barrier synchronously, before _runSignOut can yield. A
    // failed drain/auth release reopens ingress for the preserved session.
    final attempt = _SignOutAttempt(_sessionSetupGeneration);
    final completion = Completer<void>();
    attempt.task = completion.future.whenComplete(() {
      if (identical(_signOutAttempt, attempt)) _signOutAttempt = null;
    });
    _signOutAttempt = attempt;
    _runSignOut(attempt)
        .then(completion.complete, onError: completion.completeError);
    return attempt.task;
  }

  Future<void> _runSignOut(_SignOutAttempt attempt) async {
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    bool stillOwnsSession() =>
        attempt.sessionGeneration == _sessionSetupGeneration &&
        ownerScope == store.activeOwnerScope &&
        ownerId == api.currentUser?.id &&
        (!store.ownerAware ||
            (ownerId != null && store.isActiveOwner(ownerId)));
    void requireSameOwner() {
      if (!stillOwnsSession()) {
        throw StateError('Recall account changed while signing out.');
      }
    }

    // Sign-out is deliberately fail-closed: an offline review is user data,
    // not disposable cache. Settle admitted producers before flushing their
    // durable actions; joining senders alone cannot cover an ID/write await.
    await Future.wait<void>([
      for (final entry in _studyActionTasks.entries)
        if (entry.value == attempt.sessionGeneration) entry.key,
    ]);
    requireSameOwner();
    await Future.wait<void>([_flushOutbox(), _flushFlagOutbox()]);
    requireSameOwner();
    // Don't leave one user's snapshot/outbox on disk for the next person on a
    // shared browser — RLS protects the cloud, but the device cache is global.
    try {
      await store.clear(
        ownerScope: ownerScope,
        requireEmptyOutboxes: true,
        canClear: () {
          if (!stillOwnsSession()) return false;
          // The store calls this only after proving both outboxes empty in
          // its lock. Expire late snapshot writes before removing any cache;
          // a pending-action refusal keeps the existing session/Undo intact.
          _invalidateActiveSession();
          return true;
        },
      );
    } on LocalOutboxNotEmptyException catch (error) {
      throw PendingSyncException(
        pendingReviews: error.pendingReviews,
        pendingFlags: error.pendingFlags,
      );
    }
    requireSameOwner();
    await api.signOut(); // _onAuthChanged then resets in-memory state
    // Native delivery is account-scoped. Cancel only after the cloud/auth
    // session has actually been released; an offline/failed sign-out above
    // keeps the reminder armed instead of silently disabling every channel.
    // The auth event owns this release. A later account may already have
    // finished preparing while the old remote logout was still pending.
    final release = attempt.signedOutRelease;
    if (release != null) {
      await release;
    } else if (api.currentUser == null &&
        _sessionSetupGeneration == attempt.sessionGeneration) {
      // Also cover an auth adapter whose signedOut event is delivered after
      // its signOut future. That event will join this same local release.
      await _releaseAfterAuthSignOut();
    }
  }

  void _invalidateActiveSession() {
    _loadSequence++;
    _interactionGeneration++;
    _catchUpRatingProgress = null;
    _catchUpProgressRevision++;
    _undo = null;
    _hideUndo = null;
  }

  String _authMessage(Object e) {
    if (e is AuthException && e.code == 'invalid_credentials') {
      return 'Wrong email or password.';
    }
    return 'Could not sign in. Try again.';
  }

  // --- Study ---

  /// Bumped on every user interaction with the current queue (flip/rate).
  /// A network load that finishes on a stale generation must not clobber the
  /// session the user is mid-way through — it only refreshes the metadata.
  int _interactionGeneration = 0;

  /// Bumped on every load() call. A load that finishes after a newer load
  /// started (e.g. the cold all-decks fetch completing after a deck switch)
  /// is superseded and must not write anything — otherwise the UI could show
  /// the selected deck's filter over another deck's queue.
  int _loadSequence = 0;

  Future<void> initialize() => _loadSafely();

  Future<void> _loadSafely({int? deckId}) async {
    try {
      await load(deckId: deckId);
    } on LocalOutboxCorruptException {
      // Durable writes must fail closed, but malformed local storage must not
      // become another startup crash. Stop the session and surface a stable
      // recovery message without overwriting the damaged outbox.
      _set(
        _state.copyWith(
          loading: false,
          error:
              'Recall could not read the pending study actions. Reinstall '
              'only after exporting or recovering them.',
        ),
      );
    }
  }

  /// True once at least one session-driven load() has run — gates prefs-change
  /// reloads so startup hydration doesn't reload before there's a session.
  bool _sessionLoaded = false;

  /// The full, outbox-filtered queue from the latest successful fetch. The
  /// active catch-up view slices this list; keeping it separate means an
  /// opt-in/out choice never needs a server round-trip or loses the remainder
  /// behind the daily cap.
  List<ReviewCard> _catchUpSourceQueue = const [];

  /// Invalidates catch-up reads that started before a local rating finished
  /// saving progress. A refresh must rebuild from that saved progress rather
  /// than publish an older read over the rating's completed slot.
  int _catchUpProgressRevision = 0;

  /// An in-flight refresh can discover more due cards after a rating exhausts
  /// the cached source. Keep that rating's active-plan progress for this exact
  /// load so the larger source can continue the same episode. A later load,
  /// deck switch, or account invalidation has a different token.
  ({int loadToken, String? ownerScope, CatchUpLocalState state})?
  _catchUpRatingProgress;

  // A view does not expose its calendar day. Bind only views we constructed
  // from known progress, and consult the binding only for the published view.
  final _catchUpViewDays =
      Expando<({int loadToken, String? ownerScope, String dayKey})>();

  CatchUpView _bindCatchUpViewDay(CatchUpView view, DateTime now) {
    _catchUpViewDays[view] = (
      loadToken: _loadSequence,
      ownerScope: store.activeOwnerScope,
      dayKey: BacklogCatchUp.dayKey(now),
    );
    return view;
  }

  /// Decks admitted to the normal all-decks stream by the latest deck read.
  /// A direct deck selection bypasses this set so optional curricula remain
  /// fully reviewable when the learner opens them explicitly.
  Set<int> _automaticDeckIds = const {};

  /// Cards kept out of the queue by an unresolved "don't like" or "delete"
  /// flag. Server open flags are the truth; the local copy covers flags that
  /// have not synced yet and offline cold starts.
  Set<int> _hiddenCardIds = const {};

  /// Hides whose durable flag write is still in flight. A reload that
  /// re-reads storage meanwhile must keep them hidden.
  final Set<int> _hidesInFlight = {};

  Future<void> load({int? deckId, bool keepReviewed = true}) async {
    _sessionLoaded = true;
    final loadToken = ++_loadSequence;
    // Reloading (refresh/deck switch) leaves the session the last rating was
    // made in — its queue position stops meaning anything, so undo expires.
    _undo = null;
    _hideUndo = null;
    // NB: load() always applies [deckId] as the new filter (null = all decks),
    // so any difference from the current filter is a deck switch.
    final deckChanged = deckId != _state.deckFilter;
    _set(
      _state.copyWith(
        loading: true,
        error: null,
        authSubmitting: false,
        deckFilter: deckId,
        // Switching decks drops the old deck's cards right away so the study
        // screen shows the loading state, not a stale queue.
        queue: deckChanged ? const [] : null,
        index: deckChanged ? 0 : null,
        showBack: deckChanged ? false : null,
        reviewedThisSession: keepReviewed ? null : 0,
        // A normal load re-arms "Keep going" — the ahead window moved.
        aheadExhausted: false,
      ),
    );
    _previewForCardId = null;
    _previewAt = null;

    // Cold start: paint the cached snapshot immediately (a card in hand beats
    // a spinner) and let the network fetch below replace it in the background.
    // Not on a deck switch — the snapshot holds the previous filter's queue.
    final cachedHidden = await _loadHiddenCardsQuietly();
    if (loadToken != _loadSequence || cachedHidden == null) return;
    _hiddenCardIds = {...cachedHidden, ..._hidesInFlight};
    var snapshotPainted = false;
    if (!deckChanged && _state.queue.isEmpty) {
      final snapshot = await store.loadSnapshot(deckId: _state.deckFilter);
      if (loadToken != _loadSequence) return; // superseded by a newer load
      if (snapshot != null && snapshot.queue.isNotEmpty) {
        final pending = await store.outbox();
        if (loadToken != _loadSequence) return; // superseded while reading disk
        final snapshotAutomaticDeckIds = automaticReviewDeckIds(snapshot.decks);
        _automaticDeckIds = snapshotAutomaticDeckIds;
        final streamQueue = _queueForSelectedStream(
          snapshot.queue,
          deckId: _state.deckFilter,
          automaticDeckIds: snapshotAutomaticDeckIds,
        );
        final queue = _withoutPendingReviews(streamQueue, pending);
        final catchUp = await _buildCurrentCatchUpView(
          queue,
          const [],
          clearWhenEmpty: false,
          canWrite: () => loadToken == _loadSequence,
        );
        if (loadToken != _loadSequence) return;
        _catchUpSourceQueue = queue;
        final pendingLastReviewedAt = _latestPendingReviewAt(pending);
        _set(
          _state.copyWith(
            // If every cached card is still pending sync, keep the loading
            // state until the fetch resolves instead of briefly announcing
            // "All caught up". The final empty state uses the existing screen.
            loading: queue.isEmpty,
            decks: snapshot.decks,
            queue: _presentedQueue(queue, catchUp),
            index: 0,
            showBack: false,
            pendingSync: pending.length,
            globalDueCount: snapshot.globalDueCount,
            globalDueUpdatedAt: snapshot.globalDueUpdatedAt,
            catchUp: catchUp,
            lastReviewedAt: _latestReviewAt(
              _state.lastReviewedAt,
              pendingLastReviewedAt,
            ),
            reviewActivityKnown:
                _state.reviewActivityKnown || pendingLastReviewedAt != null,
          ),
        );
        snapshotPainted = true;
      }
    }

    // Push queued reviews before fetching so the fetched queue excludes them.
    // The snapshot (if any) is already on screen, so this no longer delays
    // first paint the way it used to.
    await _flushOutbox();
    // Flags have no bearing on the fetched queue, so drain them off the
    // critical path — never let a flag flush delay the load.
    unawaited(_flushFlagOutbox());

    final generationAtFetch = _interactionGeneration;
    try {
      // Independent round-trips — run them together instead of serially.
      // _refreshFsrsSettings never throws (it falls back to defaults).
      final active = _activePrefs;
      final decksFuture = api.fetchDecks();
      final hiddenFuture = _refreshHiddenCards();
      // Exclude the hidden set already known on this device so the queue
      // fetch never waits on the hidden-card read; the fresh server set still
      // filters the result below.
      final knownHidden = _hiddenCardIds;
      final queueFuture = () async {
        final decks = await decksFuture;
        final includedDeckIds = _state.deckFilter == null
            ? automaticReviewDeckIds(decks)
            : null;
        return api.fetchQueue(
          deckId: _state.deckFilter,
          includedDeckIds: includedDeckIds,
          newLimit: active.newLimitForDeck(_state.deckFilter),
          order: active.newOrder,
          excludeCardIds: knownHidden,
        );
      }();
      final globalDueFuture = () async {
        final decks = await decksFuture;
        return _fetchGlobalDueSnapshot(automaticReviewDeckIds(decks));
      }();
      final results = await Future.wait<Object?>([
        _refreshFsrsSettings(loadToken),
        decksFuture,
        queueFuture,
        globalDueFuture,
        _fetchRecentReviews(),
        hiddenFuture,
      ]);
      final decks = results[1] as List<DeckRow>;
      _automaticDeckIds = automaticReviewDeckIds(decks);
      var fetchedQueue = results[2] as List<ReviewCard>;
      if (!setEquals(knownHidden, _hiddenCardIds)) {
        // The fresh hide set differs from the cached one the query excluded
        // (flags from another device, or ones the review resolved). Refetch
        // once so hidden cards never use up the limits and resolved ones
        // return now rather than on the next load.
        fetchedQueue = await api.fetchQueue(
          deckId: _state.deckFilter,
          includedDeckIds: _state.deckFilter == null
              ? automaticReviewDeckIds(decks)
              : null,
          newLimit: active.newLimitForDeck(_state.deckFilter),
          order: active.newOrder,
          excludeCardIds: _hiddenCardIds,
        );
      }
      final fetchedDue = results[3] as ({int count, DateTime updatedAt})?;
      final recent = results[4] as _RecentReviews;
      final recentReviews = recent.reviews;
      final fetchedActivity = recent.activity;
      // A partial flush is deliberately swallowed by _flushOnce. Re-read the
      // outbox after that attempt and never serve a card whose review remains
      // queued locally, even if the server fetch still returns it.
      final pending = await store.outbox();
      if (loadToken != _loadSequence) return; // superseded by a newer load
      final queue = _withoutPendingReviews(fetchedQueue, pending);
      final catchUp = await _buildCurrentCatchUpView(
        queue,
        recentReviews,
        canWrite: () => loadToken == _loadSequence,
      );
      if (loadToken != _loadSequence) return;
      final presentedQueue = _presentedQueue(queue, catchUp);
      _catchUpSourceQueue = queue;
      _refreshCatchUpUndo(queue, catchUp);
      final pendingSync = pending.length;
      final pendingLastReviewedAt = _latestPendingReviewAt(pending);
      final lastReviewedAt = _latestReviewAt(
        _state.lastReviewedAt,
        fetchedActivity.available ? fetchedActivity.latest : null,
        pendingLastReviewedAt,
      );
      final reviewActivityKnown =
          _state.reviewActivityKnown ||
          fetchedActivity.available ||
          pendingLastReviewedAt != null;
      final sessionUnchanged = _interactionGeneration == generationAtFetch;
      final globalDueCount = sessionUnchanged && fetchedDue != null
          ? fetchedDue.count
          : _state.globalDueCount;
      final globalDueUpdatedAt = sessionUnchanged && fetchedDue != null
          ? fetchedDue.updatedAt
          : _state.globalDueUpdatedAt;
      if (sessionUnchanged) {
        _set(
          _state.copyWith(
            loading: false,
            error: null,
            offline: false,
            decks: decks,
            queue: presentedQueue,
            index: 0,
            showBack: false,
            pendingSync: pendingSync,
            globalDueCount: globalDueCount,
            globalDueUpdatedAt: globalDueUpdatedAt,
            catchUp: catchUp,
            lastReviewedAt: lastReviewedAt,
            reviewActivityKnown: reviewActivityKnown,
          ),
        );
      } else {
        // The user is already studying the snapshot queue; keep their place
        // and refresh only the metadata. The next load() picks up the rest,
        // but cards hidden meanwhile leave the upcoming part right away.
        final hidden = _hiddenCardIds;
        final upcoming = _state.index + 1;
        final retained = _state.queue.length <= upcoming || hidden.isEmpty
            ? null
            : [
                ..._state.queue.take(upcoming),
                for (final card in _state.queue.skip(upcoming))
                  if (!hidden.contains(card.id)) card,
              ];
        _set(
          _state.copyWith(
            loading: false,
            error: null,
            offline: false,
            queue: retained,
            decks: decks,
            pendingSync: pendingSync,
            globalDueCount: globalDueCount,
            globalDueUpdatedAt: globalDueUpdatedAt,
            catchUp: catchUp,
            lastReviewedAt: lastReviewedAt,
            reviewActivityKnown: reviewActivityKnown,
          ),
        );
      }
      _previewForCardId = null;
      _previewAt = null;
      // Persist off the critical path — the UI shouldn't wait on storage.
      unawaited(
        _saveSnapshotQuietly(
          loadToken: loadToken,
          decks: decks,
          queue: queue,
          globalDueCount: globalDueCount,
          globalDueUpdatedAt: globalDueUpdatedAt,
        ),
      );
    } catch (_) {
      if (loadToken != _loadSequence) return; // superseded by a newer load
      if (_state.queue.isNotEmpty) {
        // Already showing the snapshot (or an active session) — stay on it.
        _set(_state.copyWith(loading: false, error: null, offline: true));
        return;
      }
      if (snapshotPainted) {
        // The initial snapshot was valid but every card may have been filtered
        // as pending. Do not reload its raw queue after a successful flush has
        // emptied the outbox; those cards were already reviewed and delivered.
        _set(_state.copyWith(loading: false, error: null, offline: true));
        return;
      }
      final snapshot = await store.loadSnapshot(deckId: _state.deckFilter);
      if (loadToken != _loadSequence) return; // superseded while reading disk
      if (snapshot != null) {
        final pending = await store.outbox();
        if (loadToken != _loadSequence) return; // superseded while reading disk
        final snapshotAutomaticDeckIds = automaticReviewDeckIds(snapshot.decks);
        _automaticDeckIds = snapshotAutomaticDeckIds;
        final streamQueue = _queueForSelectedStream(
          snapshot.queue,
          deckId: _state.deckFilter,
          automaticDeckIds: snapshotAutomaticDeckIds,
        );
        final queue = _withoutPendingReviews(streamQueue, pending);
        final catchUp = await _buildCurrentCatchUpView(
          queue,
          const [],
          clearWhenEmpty: false,
          canWrite: () => loadToken == _loadSequence,
        );
        if (loadToken != _loadSequence) return;
        _catchUpSourceQueue = queue;
        final pendingLastReviewedAt = _latestPendingReviewAt(pending);
        _set(
          _state.copyWith(
            loading: false,
            error: null,
            offline: true,
            decks: snapshot.decks,
            queue: _presentedQueue(queue, catchUp),
            index: 0,
            showBack: false,
            pendingSync: pending.length,
            globalDueCount: snapshot.globalDueCount,
            globalDueUpdatedAt: snapshot.globalDueUpdatedAt,
            catchUp: catchUp,
            lastReviewedAt: _latestReviewAt(
              _state.lastReviewedAt,
              pendingLastReviewedAt,
            ),
            reviewActivityKnown:
                _state.reviewActivityKnown || pendingLastReviewedAt != null,
          ),
        );
      } else {
        _set(
          _state.copyWith(
            loading: false,
            error: 'Recall is offline and no saved study queue is available.',
          ),
        );
      }
    }
  }

  List<ReviewCard> _withoutPendingReviews(
    List<ReviewCard> queue,
    List<Map<String, dynamic>> pending,
  ) {
    final pendingCardIds = pending
        .map((entry) => entry['card_id'])
        .whereType<num>()
        .map((id) => id.toInt())
        .toSet();
    final hidden = _hiddenCardIds;
    if (pendingCardIds.isEmpty && hidden.isEmpty) return queue;
    return [
      for (final card in queue)
        if (!pendingCardIds.contains(card.id) && !hidden.contains(card.id))
          card,
    ];
  }

  List<ReviewCard> _queueForSelectedStream(
    List<ReviewCard> queue, {
    required int? deckId,
    required Set<int> automaticDeckIds,
  }) => [
    for (final card in queue)
      if (deckId != null
          ? card.deckId == deckId
          : automaticDeckIds.contains(card.deckId))
        card,
  ];

  /// One read serves both the catch-up threshold (the recent window) and the
  /// reminder's review-activity signal (the last two days), which used to be
  /// two separate review-log round-trips on every load.
  Future<_RecentReviews> _fetchRecentReviews() async {
    // Mirror the server-side window RecallApi.fetchReviewLog(days: 2) applied.
    final activitySince = DateTime.now().toUtc().subtract(
      const Duration(days: _reviewActivityDays),
    );
    try {
      final reviews = await api.fetchReviewLog(days: BacklogCatchUp.recentDays);
      return (
        reviews: reviews,
        activity: _reviewActivity(reviews, activitySince),
      );
    } catch (_) {
      // Recent activity only tunes the offer threshold. A stats/history
      // outage must never turn a healthy study queue into an offline screen.
      // Reminder eligibility fails closed when activity is unavailable, and a
      // later foreground refresh retries.
      debugPrint('Recall: catch-up activity unavailable (non-fatal)');
      return (
        reviews: const <ReviewLogEntry>[],
        activity: (available: false, latest: null),
      );
    }
  }

  Future<CatchUpView> _buildCurrentCatchUpView(
    List<ReviewCard> queue,
    List<ReviewLogEntry> recentReviews, {
    bool clearWhenEmpty = true,
    required bool Function() canWrite,
  }) async {
    while (canWrite()) {
      final revision = _catchUpProgressRevision;
      final view = await _buildCatchUpView(
        queue,
        recentReviews,
        clearWhenEmpty: clearWhenEmpty,
        canWrite: () => canWrite() && revision == _catchUpProgressRevision,
      );
      if (!canWrite() || revision == _catchUpProgressRevision) return view;
    }
    return _state.catchUp;
  }

  Future<CatchUpView> _buildCatchUpView(
    List<ReviewCard> queue,
    List<ReviewLogEntry> recentReviews, {
    required bool clearWhenEmpty,
    required bool Function() canWrite,
  }) async {
    final now = clock();
    final rawLocal = await store.loadCatchUpState();
    if (!canWrite()) return _state.catchUp;
    var local = BacklogCatchUp.normalizeLocalState(rawLocal, now);
    final dueCount = queue.where(_countsTowardsGlobalDue).length;
    final ratingProgress = _catchUpRatingProgress;
    if (dueCount > 0 &&
        ratingProgress != null &&
        ratingProgress.loadToken == _loadSequence &&
        ratingProgress.ownerScope == store.activeOwnerScope &&
        ratingProgress.state.mode == CatchUpMode.active &&
        local.mode != CatchUpMode.dismissed) {
      local = BacklogCatchUp.normalizeLocalState(ratingProgress.state, now);
    }
    if (local != rawLocal) {
      await _saveCatchUpStateQuietly(local, canWrite: canWrite);
      if (!canWrite()) return _state.catchUp;
    }

    final recentAverage = BacklogCatchUp.recentDailyAverage(
      recentReviews,
      now: now,
    );
    final threshold = BacklogCatchUp.thresholdForAverage(recentAverage);

    if (dueCount == 0 && clearWhenEmpty) {
      if (local.mode != CatchUpMode.none) {
        await _saveCatchUpStateQuietly(
          CatchUpLocalState.none,
          canWrite: canWrite,
        );
      }
      return _bindCatchUpViewDay(
        CatchUpView(
          dueCount: 0,
          threshold: threshold,
          recentDailyAverage: recentAverage,
          completedToday: 0,
        ),
        now,
      );
    }

    if (dueCount == 0) {
      return _bindCatchUpViewDay(
        CatchUpView(
          mode: local.mode,
          dueCount: 0,
          threshold: threshold,
          recentDailyAverage: recentAverage,
          completedToday: local.completedToday,
        ),
        now,
      );
    }

    var mode = local.mode;
    // A dismissed backlog is one episode. Once it falls below the offer
    // threshold, forget the dismissal so a later large backlog can ask again.
    if (mode == CatchUpMode.dismissed && dueCount <= threshold) {
      mode = CatchUpMode.none;
      await _saveCatchUpStateQuietly(
        CatchUpLocalState(mode: mode, dayKey: local.dayKey),
        canWrite: canWrite,
      );
    }

    return _bindCatchUpViewDay(
      CatchUpView(
        mode: mode,
        dueCount: dueCount,
        threshold: threshold,
        recentDailyAverage: recentAverage,
        completedToday: local.completedToday,
      ),
      now,
    );
  }

  List<ReviewCard> _presentedQueue(
    List<ReviewCard> source,
    CatchUpView catchUp,
  ) {
    final revalidations = [
      for (final card in source)
        if (card.contentRevalidationPending) card,
    ];
    final ordinary = [
      for (final card in source)
        if (!card.contentRevalidationPending) card,
    ];
    if (!catchUp.isActive) return [...revalidations, ...ordinary];
    final due = [
      for (final card in ordinary)
        if (!card.isNew) card,
    ];
    final ordered = BacklogCatchUp.orderDue(due, engine, now: clock());
    // New cards stay behind the existing due-card gate while a catch-up plan
    // is active; no new-card limit or server query is changed.
    return [
      ...revalidations,
      ...BacklogCatchUp.takeForToday(
        ordered,
        completedToday: catchUp.completedToday,
      ),
    ];
  }

  Future<void> _saveCatchUpStateQuietly(
    CatchUpLocalState state, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    try {
      await store.saveCatchUpState(
        state,
        ownerScope: ownerScope,
        canWrite: canWrite,
      );
    } catch (_) {
      debugPrint('Recall: catch-up progress save failed (non-fatal)');
    }
  }

  DateTime? _latestPendingReviewAt(Iterable<Map<String, dynamic>> pending) {
    DateTime? latest;
    for (final entry in pending) {
      final raw = entry['last_review'];
      if (raw is! String) continue;
      final at = DateTime.tryParse(raw);
      if (at == null || (latest != null && !at.isAfter(latest))) continue;
      latest = at;
    }
    return latest;
  }

  DateTime? _latestReviewAt(
    DateTime? first, [
    DateTime? second,
    DateTime? third,
  ]) {
    DateTime? latest;
    for (final candidate in [first, second, third]) {
      if (candidate == null || (latest != null && !candidate.isAfter(latest))) {
        continue;
      }
      latest = candidate;
    }
    return latest;
  }

  Future<void> _saveSnapshotQuietly({
    required int loadToken,
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
    required int? globalDueCount,
    required DateTime? globalDueUpdatedAt,
  }) async {
    try {
      if (loadToken != _loadSequence) return;
      await store.saveSnapshot(
        decks: decks,
        queue: queue,
        deckId: _state.deckFilter,
        globalDueCount: globalDueCount,
        globalDueUpdatedAt: globalDueUpdatedAt,
        canWrite: () => loadToken == _loadSequence,
      );
    } catch (_) {
      debugPrint('Recall: snapshot save failed (non-fatal)');
    }
  }

  /// Widget metadata is useful but optional: an unavailable aggregate RPC
  /// must never turn a healthy study queue into an offline/error screen.
  Future<({int count, DateTime updatedAt})?> _fetchGlobalDueSnapshot(
    Set<int> automaticDeckIds,
  ) async {
    try {
      final deckCounts = await api.fetchDeckCounts();
      return (
        count: deckCounts.entries.fold<int>(
          0,
          (total, entry) =>
              total +
              (automaticDeckIds.contains(entry.key) ? entry.value.due : 0),
        ),
        updatedAt: clock().toUtc(),
      );
    } catch (_) {
      debugPrint('Recall: widget due count unavailable (non-fatal)');
      return null;
    }
  }

  /// Review activity is a safe aggregate signal: only the most recent review
  /// timestamp crosses into reminder state, never card content or private text.
  /// A two-day window covers every local calendar day even around UTC offsets
  /// and daylight-saving transitions; the API returns local timestamps for the
  /// day comparison performed by the reminder controller.
  static const int _reviewActivityDays = 2;

  ReviewActivitySnapshot _reviewActivity(
    List<ReviewLogEntry> reviews,
    DateTime since,
  ) {
    DateTime? latest;
    for (final review in reviews) {
      if (review.at.isBefore(since)) continue;
      if (latest == null || review.at.isAfter(latest)) latest = review.at;
    }
    return (available: true, latest: latest?.toLocal());
  }

  Future<void> _refreshFsrsSettings(int loadToken) async {
    try {
      final settings = await api.fetchFsrsSettings();
      if (loadToken != _loadSequence) return;
      if (settings != null) {
        engine.configure(settings);
      } else {
        engine.resetToDefaults();
      }
    } catch (_) {
      if (loadToken != _loadSequence) return;
      engine.resetToDefaults();
      debugPrint('Recall: FSRS settings unavailable, using defaults');
    }
    // Stored study prefs are the source of truth for desired retention; the
    // fsrs_params retention above only fills in when the user hasn't set one.
    if (loadToken != _loadSequence) return;
    final p = prefs;
    if (p != null && p.hasStoredPrefs) {
      engine.setDesiredRetention(p.value.desiredRetention);
      _appliedPrefs = p.value;
    }
  }

  Future<void> refresh() => load(deckId: _state.deckFilter);

  /// Refreshes a stale aggregate after foregrounding without displacing an
  /// active card. The outbox is flushed by [load] before the cloud count is
  /// fetched, so the widget and queue reflect all locally completed reviews.
  Future<void> refreshIfIdle({Duration maxAge = const Duration(minutes: 15)}) {
    if (_state.loading || _state.current != null || api.currentUser == null) {
      return Future<void>.value();
    }
    final updatedAt = _state.globalDueUpdatedAt;
    if (updatedAt != null && clock().toUtc().difference(updatedAt) < maxAge) {
      return Future<void>.value();
    }
    return _loadSafely(deckId: _state.deckFilter);
  }

  Future<void> selectDeck(int? deckId) =>
      load(deckId: deckId, keepReviewed: false);

  /// Opt into the currently offered catch-up episode. This only changes the
  /// local presentation list; it does not reload, reschedule, or write a card.
  Future<void> startCatchUp() => _chooseCatchUpMode(CatchUpMode.active);

  /// Dismiss the current offer and keep the ordinary due-date queue for this
  /// backlog episode. The dismissal is local and expires once the backlog is
  /// no longer above its threshold.
  Future<void> showAll() => _chooseCatchUpMode(CatchUpMode.dismissed);

  Future<void> _chooseCatchUpMode(CatchUpMode mode) async {
    final allowed = mode == CatchUpMode.active
        ? _state.catchUp.shouldOffer
        : _state.catchUp.shouldOffer || _state.catchUp.isActive;
    if (!allowed) return;

    final now = clock();
    final current = BacklogCatchUp.normalizeLocalState(
      await store.loadCatchUpState(),
      now,
    );
    final nextLocal = current.copyWith(
      mode: mode,
      dayKey: BacklogCatchUp.dayKey(now),
    );
    await store.saveCatchUpState(nextLocal);

    // Re-read the pending set before rebuilding the display list. A rating may
    // have landed while the offer was visible; the outbox filter remains the
    // same safety boundary as every normal load.
    final pending = await store.outbox();
    final source = _withoutPendingReviews(_catchUpSourceQueue, pending);
    _catchUpSourceQueue = source;
    final view = _bindCatchUpViewDay(
      _state.catchUp.copyWith(
        mode: mode,
        dueCount: source.where(_countsTowardsGlobalDue).length,
        completedToday: nextLocal.completedToday,
      ),
      now,
    );
    _catchUpRatingProgress = null;
    _catchUpProgressRevision++;
    _interactionGeneration++;
    _undo = null;
    _hideUndo = null;
    _set(
      _state.copyWith(
        loading: false,
        error: null,
        offline: false,
        queue: mode == CatchUpMode.active
            ? _presentedQueue(source, view)
            : source,
        index: 0,
        showBack: false,
        catchUp: view,
        aheadExhausted: false,
      ),
    );
  }

  /// "Keep going" after the daily queue: load a bonus batch of cards due
  /// within the next 24 hours (soonest first — which recaptures learning
  /// cards that came due minutes ahead) topped up with unseen new cards.
  /// The session counter keeps running; each finished batch lands back on
  /// the done screen, where the button stays until a fetch comes back empty.
  ///
  /// Cloud-only by design: the ratings just made must be on the server before
  /// fetching, or the batch would re-serve those cards with their pre-rating
  /// scheduling. The daily snapshot is deliberately not overwritten — a cold
  /// start should paint the real queue, not a bonus batch.
  Future<void> keepGoing() async {
    // No auth guard (load() has none either): the button only renders on the
    // done screen, which a signed-out session never reaches.
    if (_state.loading) return;
    // A catch-up plan is the daily cap. Do not let the ordinary bonus batch
    // bypass it with cards due later or new cards.
    if (_state.catchUp.isActive) return;
    final loadToken = ++_loadSequence;
    _undo = null; // the finished queue's positions stop meaning anything
    _hideUndo = null;
    _set(_state.copyWith(loading: true, error: null));
    _previewForCardId = null;
    _previewAt = null;

    await _flushOutbox();
    if (loadToken != _loadSequence) return;
    if ((await store.outbox()).isNotEmpty) {
      // Undelivered ratings — offline. Stay on the done screen; it explains
      // that bonus cards need a connection.
      if (loadToken != _loadSequence) return;
      _set(_state.copyWith(loading: false, offline: true));
      return;
    }

    try {
      final queue = _withoutPendingReviews(
        await api.fetchAheadQueue(
          deckId: _state.deckFilter,
          includedDeckIds: _state.deckFilter == null ? _automaticDeckIds : null,
          order: _activePrefs.newOrder,
          excludeCardIds: _hiddenCardIds,
        ),
        const [],
      );
      if (loadToken != _loadSequence) return;
      _set(
        _state.copyWith(
          loading: false,
          error: null,
          offline: false,
          queue: queue,
          index: 0,
          showBack: false,
          aheadExhausted: queue.isEmpty,
        ),
      );
      _previewForCardId = null;
      _previewAt = null;
    } catch (_) {
      debugPrint('Recall: keep-going fetch failed (offline?)');
      if (loadToken != _loadSequence) return;
      _set(_state.copyWith(loading: false, offline: true));
    }
  }

  /// Flush queued reviews AND queued flags without reloading the queue — safe
  /// on foreground/app-resume. The two loops run concurrently and each swallows
  /// its own failures, so a stuck flag flush can never delay the review flush.
  Future<void> syncPending() => Future.wait<void>([
    _flushOutbox(),
    _flushFlagOutbox(),
    if (prefs != null) prefs!.syncOwner(),
  ]);

  /// Flush durable study actions and summarize the result for iOS background
  /// fetch. A failed network attempt leaves every undelivered entry in place.
  Future<BackgroundSyncReport> syncPendingInBackground() async {
    final ownerScope = store.activeOwnerScope;
    if (ownerScope == null) {
      return const BackgroundSyncReport(attempted: 0, delivered: 0, pending: 0);
    }
    final beforeReviews = (await store.outbox(ownerScope: ownerScope)).length;
    final beforeFlags = (await store.flagOutbox(ownerScope: ownerScope)).length;
    final attempted = beforeReviews + beforeFlags;
    await syncPending();
    final pending =
        (await store.outbox(ownerScope: ownerScope)).length +
        (await store.flagOutbox(ownerScope: ownerScope)).length;
    return BackgroundSyncReport(
      attempted: attempted,
      delivered: (attempted - pending).clamp(0, attempted),
      pending: pending,
    );
  }

  void flip() {
    if (_state.current != null && !_state.showBack) {
      _interactionGeneration++;
      _set(_state.copyWith(showBack: true));
      haptics.reveal();
    }
  }

  /// FSRS interval preview for the four rating buttons, cached per card so a
  /// rebuild (e.g. a pending-sync tick) doesn't re-run the scheduler 4×.
  int? _previewForCardId;
  Map<Rating, DateTime> _preview = const {};
  DateTime? _previewAt;

  DateTime? get previewCurrentAt => _previewAt;

  Map<Rating, DateTime> previewCurrent() {
    final card = _state.current;
    if (card == null) return const {};
    if (_previewForCardId != card.id) {
      _previewAt = clock().toUtc();
      _preview = engine.preview(card, now: _previewAt);
      _previewForCardId = card.id;
    }
    return _preview;
  }

  // --- Elapsed time (time-on-card) ---

  /// Ceiling for elapsed_ms: a walked-away-from card records five minutes,
  /// not an afternoon, so it can't poison the time stats.
  static const int maxElapsedMs = 300000;

  /// The card whose on-screen time is being measured, and since when. Updated
  /// centrally in [_set] whenever a different card's front comes on screen.
  int? _timedCardId;
  DateTime? _cardShownAt;

  bool _rateInFlight = false;
  bool get rateInFlight => _rateInFlight;

  Future<void> rate(Rating rating) => _runStudyAction(() => _rate(rating));

  Future<void> _rate(Rating rating) async {
    final card = _state.current;
    // Local persistence is intentionally awaited before the UI advances. Lock
    // that window too: two fast taps must never enqueue the same visible card
    // twice while its first durable event id is still being minted.
    if (card == null || !_state.showBack || _undoInFlight || _rateInFlight) {
      return;
    }
    _rateInFlight = true;
    notifyListeners();
    try {
      await _rateVisibleCard(card, rating);
    } finally {
      _rateInFlight = false;
      _ratingClientId = null;
      notifyListeners();
    }
  }

  /// The event id of the rating being persisted, which may become [_undo]
  /// once its local commit settles. A flush must not close its Undo window
  /// early by marking it attempted in a batch.
  Object? _ratingClientId;

  Future<void> _rateVisibleCard(ReviewCard card, Rating rating) async {
    var ratingGeneration = ++_interactionGeneration;
    final session = _state;
    final loadToken = _loadSequence;
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    final countsTowardsGlobalDue = _countsTowardsGlobalDue(card);
    bool sessionCurrent() =>
        ownerScope == store.activeOwnerScope &&
        ownerId == api.currentUser?.id &&
        (!store.ownerAware ||
            (ownerId != null && store.isActiveOwner(ownerId))) &&
        ratingGeneration == _interactionGeneration &&
        session.deckFilter == _state.deckFilter;
    bool ratingCurrent() =>
        sessionCurrent() &&
        session.index == _state.index &&
        identical(card, _state.current);
    bool canAppend() => loadToken == _loadSequence && ratingCurrent();

    final reviewedAt = clock().toUtc();
    final outcome = engine.review(card, rating, now: reviewedAt);
    final shownAt = _cardShownAt;
    final elapsedMs = shownAt == null
        ? null
        : clock().difference(shownAt).inMilliseconds.clamp(0, maxElapsedMs);
    final entry = api.reviewEntry(card, outcome, elapsedMs: elapsedMs);
    final remediationNodeIds = entry['lapsed'] == true
        ? ConceptAttribution.nodeTags(card.tags)
        : const <String>[];
    // The queue's card remains the pre-rating scheduling snapshot. Catch-up
    // Undo metadata is captured after enqueue, when a concurrent refresh may
    // have expanded the remaining source.
    final clientId = await _reviewClientId(card.id, ownerScope);
    _ratingClientId = clientId;
    // A deck/account change before commit cancels this producer. Recheck in
    // the store lock too, since enqueue can wait behind another local write.
    if (!canAppend()) return;
    // Two jobs, both of which need this id to be unique forever: it is how an
    // undo finds its own entry in the durable outbox, AND the `client_event_id`
    // RecallApi.applyReview sends — so a repeat would make the server discard a
    // genuine review as a replay. See [LocalReviewStore.newEventId].
    entry['client_id'] = clientId;
    // enqueueReview is local storage (fast, and it must land before the next
    // card so the review can never be lost); it also returns the new pending
    // count so advancing doesn't re-read + re-decode the whole outbox.
    var appendAdmitted = false;
    int pending;
    try {
      pending = await store.enqueueReview(
        entry,
        ownerScope: ownerScope,
        canWrite: () {
          appendAdmitted = canAppend();
          return appendAdmitted;
        },
      );
    } catch (error, stackTrace) {
      final int? saved;
      try {
        saved = await _savedDespite(
          error,
          stackTrace,
          () => store.settleUnknownReview(clientId, ownerScope: ownerScope),
        );
      } on StudyActionUnconfirmedException {
        // It may be stored, so the card stays on its answer and a redo of it
        // reuses this id: the store and server keep at most one copy.
        _unconfirmedReview = (
          cardId: card.id,
          clientId: clientId,
          ownerScope: ownerScope,
        );
        if (sessionCurrent()) _showFlagNotice(saveUnconfirmedNotice);
        rethrow;
      }
      _confirmedReview(clientId);
      if (saved == null) {
        // Nothing was stored, so the card stays on its answer for a redo,
        // which gets a fresh id and is the only copy that can persist.
        if (sessionCurrent()) _showFlagNotice(saveRefusedNotice);
        _throwNotSaved(error, stackTrace);
      }
      // A thrown write that native truth holds was saved: advance normally.
      pending = saved;
    }
    // A cancelled producer wrote nothing, so a reused id stays unconfirmed.
    if (appendAdmitted) _confirmedReview(clientId);
    // A cancelled producer returns the existing pending count without an
    // append. Once admitted and acknowledged, a same-deck reload must still
    // consume this visible card, even if its fetch fails and retains it.
    // Owner/deck/presentation changes leave the event in its original outbox.
    if (!appendAdmitted || !ratingCurrent()) return;
    // A refresh that started during the native acknowledgement must preserve
    // this committed interaction rather than replace its presentation later.
    ratingGeneration = ++_interactionGeneration;
    if (remediationNodeIds.isNotEmpty) {
      try {
        await store.enqueueRemediation(
          remediationNodeIds,
          now: clock(),
          ownerScope: ownerScope,
          canWrite: ratingCurrent,
        );
        if (!ratingCurrent()) return;
        _remediationRevision++;
      } catch (_) {
        // The review is durable and must still advance if the disposable
        // cache is unavailable; remediation can be retried by a later lapse.
        debugPrint('Recall: remediation enqueue skipped (non-fatal)');
      }
    }
    final catchUpBefore = await _recordCatchUpReview(
      card,
      countsTowardsGlobalDue: countsTowardsGlobalDue,
      ownerScope: ownerScope,
      canWrite: ratingCurrent,
    );
    if (!ratingCurrent() || catchUpBefore == null) return;
    // A background load may refresh the upcoming source while this rating
    // awaits persistence. Remove only the rated card from that live source.
    _catchUpSourceQueue = [
      for (final sourceCard in _catchUpSourceQueue)
        if (sourceCard.id != card.id) sourceCard,
    ];
    // Reloads expire Undo even when they retained the same visible card.
    // A background refresh within the original load may have expanded the
    // source, so restore the live pre-progress backlog rather than the cache
    // captured before enqueue waited for its native acknowledgement.
    _undo = loadToken != _loadSequence
        ? null
        : _UndoRecord(
            clientId: clientId,
            card: card,
            index: session.index,
            catchUp: catchUpBefore.view,
            catchUpSourceQueue: catchUpBefore.source,
            previousLastReviewedAt: session.lastReviewedAt,
            previousReviewActivityKnown: session.reviewActivityKnown,
          );
    _hideUndo = null;
    _clearFlagNotice();
    if (!ratingCurrent()) return;
    haptics.rating();
    final globalDueCount = _state.globalDueCount;
    _set(
      _state.copyWith(
        index: _state.index + 1,
        showBack: false,
        reviewedThisSession: _state.reviewedThisSession + 1,
        lastReviewedAt: _latestReviewAt(_state.lastReviewedAt, reviewedAt),
        reviewActivityKnown: true,
        pendingSync: pending,
        globalDueCount: !countsTowardsGlobalDue || globalDueCount == null
            ? globalDueCount
            : (globalDueCount - 1).clamp(0, globalDueCount),
      ),
    );
    if (!sessionCurrent()) return;
    if (_state.isDone) {
      haptics.completion();
    }
    if (card.contentRevalidationPending && rating != Rating.again) {
      // The cloud review log remains authoritative, but the disposable
      // snapshot must converge too. Otherwise a successful online review
      // followed by an offline restart could repaint this validation card
      // after its outbox entry had already been removed.
      unawaited(
        _saveSnapshotQuietly(
          loadToken: _loadSequence,
          decks: _state.decks,
          queue: _catchUpSourceQueue,
          globalDueCount: _state.globalDueCount,
          globalDueUpdatedAt: _state.globalDueUpdatedAt,
        ),
      );
    }
    // Sync behind the UI — the next card must never wait on the network.
    if (!_state.offline) unawaited(_flushOutbox());
  }

  Future<({CatchUpView view, List<ReviewCard> source})?> _recordCatchUpReview(
    ReviewCard card, {
    required bool countsTowardsGlobalDue,
    required String? ownerScope,
    required bool Function() canWrite,
  }) async {
    if (!canWrite()) return null;
    final initial = _state.catchUp;
    if (!countsTowardsGlobalDue) {
      return (
        view: initial,
        source: List<ReviewCard>.unmodifiable([
          if (!_catchUpSourceQueue.any((candidate) => candidate.id == card.id))
            card,
          ..._catchUpSourceQueue,
        ]),
      );
    }

    final now = clock();
    final today = BacklogCatchUp.dayKey(now);
    CatchUpLocalState? local;
    if (initial.isActive) {
      try {
        local = BacklogCatchUp.normalizeLocalState(
          await store.loadCatchUpState(),
          now,
        );
      } catch (_) {
        // The review already has its durable ACK. Optional progress must not
        // leave the rated card visible and invite a second event for it.
        debugPrint('Recall: catch-up progress read skipped (non-fatal)');
      }
    }
    if (!canWrite()) return null;
    // A binding is consulted only in the published view's construction
    // context. A view retained across a failed or offline load outlives the
    // loads that kept it, so match the published binding rather than the live
    // load sequence; a rebuilt view supersedes older bindings on its own.
    final publishedToken = _catchUpViewDays[_state.catchUp]?.loadToken;
    int publishedProgress(CatchUpView view) {
      final context = _catchUpViewDays[view];
      return view.isActive &&
              context != null &&
              publishedToken != null &&
              context.loadToken == publishedToken &&
              context.ownerScope == ownerScope &&
              context.dayKey == today
          ? view.completedToday
          : 0;
    }

    // Fix the increment once. A refresh can read our saved progress while a
    // retry waits on native persistence; it must not count this rating again.
    final active = initial.isActive || _state.catchUp.isActive;
    var completedToday = local?.mode == CatchUpMode.active
        ? local!.completedToday
        : math.max(
            publishedProgress(initial),
            publishedProgress(_state.catchUp),
          );
    final ratingProgress = _catchUpRatingProgress;
    if (ratingProgress != null &&
        ratingProgress.loadToken == _loadSequence &&
        ratingProgress.ownerScope == ownerScope &&
        ratingProgress.state.mode == CatchUpMode.active &&
        ratingProgress.state.dayKey == today) {
      // A refused optional save does not undo a completed local rating. A
      // newer native count can still raise this same-owner, same-day floor.
      completedToday = math.max(
        completedToday,
        ratingProgress.state.completedToday,
      );
    }
    if (active) completedToday++;

    while (canWrite()) {
      final current = _state.catchUp;
      final source = _catchUpSourceQueue;
      // A fresh outbox-filtered source may already omit the rated card. Count
      // the remaining cards directly so that refresh never decrements it twice.
      final dueCount = source
          .where(
            (candidate) =>
                candidate.id != card.id && _countsTowardsGlobalDue(candidate),
          )
          .length;
      var mode = current.isNone ? initial.mode : current.mode;
      if (active && mode == CatchUpMode.none) mode = CatchUpMode.active;
      final activeCompleted = completedToday;
      final before = _bindCatchUpViewDay(
        current.copyWith(
          mode: mode,
          dueCount: dueCount + 1,
          completedToday: mode == CatchUpMode.active
              ? activeCompleted - 1
              : current.completedToday,
        ),
        now,
      );
      var nextCompleted = mode == CatchUpMode.active
          ? activeCompleted
          : current.completedToday;
      if (dueCount == 0 ||
          (mode == CatchUpMode.dismissed && dueCount <= current.threshold)) {
        mode = CatchUpMode.none;
        nextCompleted = 0;
      }
      final next = _bindCatchUpViewDay(
        current.copyWith(
          mode: mode,
          dueCount: dueCount,
          completedToday: nextCompleted,
        ),
        now,
      );
      bool contextCurrent() =>
          canWrite() &&
          identical(current, _state.catchUp) &&
          identical(source, _catchUpSourceQueue);
      if (next.isNone && !before.isNone) {
        await _saveCatchUpStateQuietly(
          CatchUpLocalState.none,
          ownerScope: ownerScope,
          canWrite: contextCurrent,
        );
      } else if (next.isActive) {
        await _saveCatchUpStateQuietly(
          CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: BacklogCatchUp.dayKey(now),
            completedToday: nextCompleted,
          ),
          ownerScope: ownerScope,
          canWrite: contextCurrent,
        );
      }
      if (!canWrite()) return null;
      if (!contextCurrent()) continue;
      if (active) {
        _catchUpRatingProgress = (
          loadToken: _loadSequence,
          ownerScope: ownerScope,
          state: CatchUpLocalState(
            mode: CatchUpMode.active,
            dayKey: BacklogCatchUp.dayKey(now),
            completedToday: activeCompleted,
          ),
        );
      }
      _catchUpProgressRevision++;
      // Publish before returning across an async boundary. The rating caller
      // keeps whatever newer refresh metadata arrives after this point.
      _set(_state.copyWith(catchUp: next));
      return (
        view: before,
        source: List<ReviewCard>.unmodifiable([
          if (!source.any((candidate) => candidate.id == card.id)) card,
          ...source,
        ]),
      );
    }
    return null;
  }

  Future<void> _restoreCatchUpState(
    CatchUpView view, {
    required String? ownerScope,
    required bool Function() canWrite,
  }) async {
    if (!canWrite()) return;
    if (view.mode == CatchUpMode.none) {
      await _saveCatchUpStateQuietly(
        CatchUpLocalState.none,
        ownerScope: ownerScope,
        canWrite: canWrite,
      );
      if (!canWrite()) return;
      _catchUpRatingProgress = null;
      _catchUpProgressRevision++;
      return;
    }
    final now = clock();
    final raw = await store.loadCatchUpStateForOwner(ownerScope);
    if (!canWrite()) return;
    final local = BacklogCatchUp.normalizeLocalState(raw, now);
    final completedToday =
        raw.mode == CatchUpMode.none || raw.dayKey == BacklogCatchUp.dayKey(now)
        ? view.completedToday
        : local.completedToday;
    await _saveCatchUpStateQuietly(
      CatchUpLocalState(
        mode: view.mode,
        dayKey: BacklogCatchUp.dayKey(now),
        completedToday: completedToday,
      ),
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
    if (!canWrite()) return;
    _catchUpRatingProgress = null;
    _catchUpProgressRevision++;
  }

  void _refreshCatchUpUndo(List<ReviewCard> source, CatchUpView view) {
    final undo = _undo;
    if (undo == null || _undoInFlight) return;
    final containsRatedCard = source.any((card) => card.id == undo.card.id);
    _undo = _UndoRecord(
      clientId: undo.clientId,
      card: undo.card,
      index: undo.index,
      catchUp: view.copyWith(
        mode: undo.catchUp.mode,
        dueCount:
            view.dueCount +
            (!containsRatedCard && _countsTowardsGlobalDue(undo.card) ? 1 : 0),
        completedToday: undo.catchUp.completedToday,
      ),
      catchUpSourceQueue: List<ReviewCard>.unmodifiable([
        if (!containsRatedCard) undo.card,
        ...source,
      ]),
      previousLastReviewedAt: undo.previousLastReviewedAt,
      previousReviewActivityKnown: undo.previousReviewActivityKnown,
    );
  }

  // --- Flag a bad card (report to the desktop revision pipeline) ---

  /// Reasons a card can be flagged — the CHECK-constrained `reason` values the
  /// note_flags table accepts.
  static const Set<String> flagReasons = {
    'wrong',
    'confusing',
    'too_long',
    'duplicate',
    ...hideReasons,
  };

  /// One-tap reasons that also take the card out of rotation until the weekly
  /// review resolves the flag: `dislike` asks for a rewrite, `delete` asks for
  /// removal.
  static const Set<String> hideReasons = {'dislike', 'delete'};

  /// Flag-outbox entry kind that withdraws an undone one-tap flag on the
  /// server. Plain flag entries carry no `op`.
  static const String dismissOp = 'dismiss';

  /// Queue a bad-card report for the current card and kick off a flag flush.
  /// Flagging is a pure side-channel: it never rates, skips, or advances the
  /// card, and the review flow is left entirely untouched. Flagging the same
  /// card twice is allowed (no client-side dedupe). A no-op with no current
  /// card or an unrecognized reason.
  ///
  /// The record is durable: it lands in a separate flag outbox and, like a
  /// review, survives an offline session. Its `client_id` comes from the same
  /// install-scoped minter reviews use, so it stays unique across restarts and
  /// across devices — `note_flags` dedupes on it exactly like `review_log`.
  Future<void> flag(String reason) => _runStudyAction(() => _flag(reason));

  Future<void> _flag(String reason) async {
    final card = _state.current;
    if (card == null ||
        !flagReasons.contains(reason) ||
        hideReasons.contains(reason)) {
      return;
    }
    final clientId = await _flagClientId();
    final entry = <String, dynamic>{
      'card_id': card.id,
      'guid': card.guid,
      'reason': reason,
      'flagged_at': clock().toUtc().toIso8601String(),
      'device': api.device,
      'client_id': clientId,
    };
    try {
      await store.enqueueFlag(entry);
    } catch (error, stackTrace) {
      final int? saved;
      try {
        saved = await _savedDespite(
          error,
          stackTrace,
          () => store.settleUnknownFlag(clientId),
        );
      } on StudyActionUnconfirmedException {
        _unconfirmedFlagId = clientId;
        _showFlagNotice(saveUnconfirmedNotice);
        rethrow;
      }
      if (saved == null) {
        _showFlagNotice(saveRefusedNotice);
        _throwNotSaved(error, stackTrace);
      }
    }
    _showFlagNotice('Flagged for the weekly review');
    // Send behind the UI; a failure (e.g. table not created yet) just leaves
    // the flag queued for the next flush.
    unawaited(_flushFlagOutbox());
  }

  /// One-tap flag that also hides the card: it is queued durably like any
  /// flag, the card leaves the queue without a rating, and it stays hidden
  /// until the weekly review resolves or dismisses the flag. The undo button
  /// brings it back.
  Future<void> hideCurrent(String reason) =>
      _runStudyAction(() => _hideCurrent(reason));

  Future<void> _hideCurrent(String reason) async {
    final card = _state.current;
    if (card == null ||
        !hideReasons.contains(reason) ||
        _undoInFlight ||
        _rateInFlight) {
      return;
    }
    _rateInFlight = true;
    // Mark the interaction and hide the card before any await, so a refresh
    // landing meanwhile keeps this session's queue and filters the card out.
    _interactionGeneration++;
    final wasHidden = _hiddenCardIds.contains(card.id);
    _hiddenCardIds = {..._hiddenCardIds, card.id};
    _hidesInFlight.add(card.id);
    notifyListeners();
    void restoreVisibility() {
      // Nothing durable was recorded, so the card is not hidden.
      _hidesInFlight.remove(card.id);
      if (!wasHidden) {
        _hiddenCardIds = {..._hiddenCardIds}..remove(card.id);
      }
    }

    try {
      final String clientId;
      try {
        clientId = await _flagClientId();
      } catch (_) {
        restoreVisibility();
        rethrow;
      }
      try {
        await store.enqueueFlag(<String, dynamic>{
          'card_id': card.id,
          'guid': card.guid,
          'reason': reason,
          'flagged_at': clock().toUtc().toIso8601String(),
          'device': api.device,
          'client_id': clientId,
        });
      } catch (error, stackTrace) {
        final int? saved;
        try {
          saved = await _savedDespite(
            error,
            stackTrace,
            () => store.settleUnknownFlag(clientId),
          );
        } on StudyActionUnconfirmedException {
          restoreVisibility();
          _unconfirmedFlagId = clientId;
          _showFlagNotice(saveUnconfirmedNotice);
          rethrow;
        }
        if (saved == null) {
          restoreVisibility();
          _showFlagNotice(saveRefusedNotice);
          _throwNotSaved(error, stackTrace);
        }
      }
      _hidesInFlight.remove(card.id);
      unawaited(_quietly(() => store.addHiddenCard(card.id)));
      if (_state.current?.id != card.id) {
        // The queue changed under the awaits and now shows another card.
        // Drop the hidden one from what is still ahead; there is no position
        // of ours to advance or restore.
        final upcoming = _state.index + 1;
        if (_state.queue.skip(upcoming).any((c) => c.id == card.id)) {
          _set(
            _state.copyWith(
              queue: [
                ..._state.queue.take(upcoming),
                for (final c in _state.queue.skip(upcoming))
                  if (c.id != card.id) c,
              ],
            ),
          );
        }
        _showFlagNotice(
          reason == 'delete'
              ? 'Marked for deletion'
              : 'Hidden until Sunday review',
        );
        return;
      }
      _undo = null;
      _hideUndo = _HideUndoRecord(
        card: card,
        index: _state.index,
        clientId: clientId,
      );
      _showFlagNotice(
        reason == 'delete'
            ? 'Marked for deletion'
            : 'Hidden until Sunday review',
      );
      haptics.rating();
      final globalDueCount = _state.globalDueCount;
      _set(
        _state.copyWith(
          index: _state.index + 1,
          showBack: false,
          globalDueCount:
              !_countsTowardsGlobalDue(card) || globalDueCount == null
              ? globalDueCount
              : (globalDueCount - 1).clamp(0, globalDueCount),
        ),
      );
      if (_state.isDone) haptics.completion();
    } finally {
      _rateInFlight = false;
      notifyListeners();
    }
    unawaited(_flushFlagOutbox());
  }

  _HideUndoRecord? _hideUndo;

  Future<void> _undoHide(_HideUndoRecord record) async {
    _undoInFlight = true;
    notifyListeners();
    try {
      // Settle any flag flush so the entry is definitely either still queued
      // or already delivered.
      while (_flagFlushTask != null) {
        try {
          await _flagFlushTask;
        } catch (_) {}
      }
      if (!identical(_hideUndo, record)) return;
      final loadSequence = _loadSequence;
      // A queued entry is not proof the server never saw the flag: a commit
      // whose reply was lost stays queued too. Drop the entry, then always
      // withdraw on the server, queueing a durable withdrawal when offline.
      await store.removeFlagEntry(record.clientId);
      try {
        await api.dismissFlag(
          cardId: record.card.id,
          clientEventId: record.clientId,
        );
      } catch (_) {
        try {
          await store.enqueueFlag(<String, dynamic>{
            'op': dismissOp,
            'card_id': record.card.id,
            'client_id': record.clientId,
          });
        } catch (_) {
          debugPrint('Recall: flag undo could not be recorded');
          return;
        }
      }
      _hiddenCardIds = {..._hiddenCardIds}..remove(record.card.id);
      unawaited(_quietly(() => store.removeHiddenCard(record.card.id)));
      _clearFlagNotice();
      if (!identical(_hideUndo, record) || loadSequence != _loadSequence) {
        // A reload or deck switch replaced the queue while the withdrawal
        // was in flight; the flag is withdrawn, but there is no position to
        // restore in the new queue.
        return;
      }
      _hideUndo = null;
      _interactionGeneration++;
      final globalDueCount = _state.globalDueCount;
      final queue = _state.queue;
      final at =
          record.index < queue.length &&
              queue[record.index].id == record.card.id
          ? null
          : record.index.clamp(0, queue.length);
      _set(
        _state.copyWith(
          // Bring back the hidden card itself even if the queue around it
          // changed, never whatever now sits at the old index.
          queue: at == null
              ? null
              : [
                  ...queue.take(at).where((c) => c.id != record.card.id),
                  record.card,
                  ...queue.skip(at).where((c) => c.id != record.card.id),
                ],
          index: at ?? record.index,
          showBack: false,
          globalDueCount:
              !_countsTowardsGlobalDue(record.card) || globalDueCount == null
              ? globalDueCount
              : globalDueCount + 1,
        ),
      );
      haptics.undo();
    } finally {
      _undoInFlight = false;
      notifyListeners();
    }
  }

  /// The cached hidden set plus the durable flag outbox. The outbox is the
  /// crash-safe record: the cache write after a hide is best-effort, so a
  /// queued hide must count even if the cache never saw it.
  /// Returns null when another load or account superseded these reads.
  Future<Set<int>?> _loadHiddenCardsQuietly() async {
    final loadToken = _loadSequence;
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    bool stillCurrent() =>
        loadToken == _loadSequence &&
        ownerId == api.currentUser?.id &&
        _flushStillOwnsSession(ownerId, ownerScope);
    if (!stillCurrent()) return null;
    Set<int> cached;
    try {
      cached = await store.hiddenCardIds();
    } catch (_) {
      cached = _hiddenCardIds;
    }
    if (!stillCurrent()) return null;
    try {
      final pending = await store.flagOutbox(ownerScope: ownerScope);
      return stillCurrent() ? _applyPendingFlagOps(cached, pending) : null;
    } catch (_) {
      return stillCurrent() ? cached : null;
    }
  }

  /// Apply queued hides and withdrawals, oldest first, on top of [base].
  Set<int> _applyPendingFlagOps(
    Set<int> base,
    List<Map<String, dynamic>> pending,
  ) {
    final next = <int>{...base};
    for (final entry in pending) {
      final id = entry['card_id'];
      if (id is! num) continue;
      if (entry['op'] == dismissOp) {
        next.remove(id.toInt());
      } else if (hideReasons.contains(entry['reason'])) {
        next.add(id.toInt());
      }
    }
    return next;
  }

  /// Replace the hidden set with the server's open hide flags plus any that
  /// have not synced. A failed read keeps the local set, so an outage never
  /// brings hidden cards back.
  Future<void> _refreshHiddenCards() async {
    final loadToken = _loadSequence;
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    bool stillCurrent() =>
        loadToken == _loadSequence &&
        ownerId == api.currentUser?.id &&
        _flushStillOwnsSession(ownerId, ownerScope);
    if (!stillCurrent()) return;
    final before = _hiddenCardIds;
    // Read the local queue before the server: a flag delivered between the
    // two reads is then either still queued here or already visible there.
    final List<Map<String, dynamic>> pending;
    try {
      pending = await store.flagOutbox(ownerScope: ownerScope);
    } catch (_) {
      return;
    }
    if (!stillCurrent()) return;
    Set<int>? server;
    try {
      server = await api.fetchHiddenCardIds();
    } catch (_) {
      server = null;
    }
    if (!stillCurrent()) return;
    if (server == null) {
      // Offline: the server truth is unknown, but queued hides are durable
      // and must still apply on top of the local set.
      final local = _applyPendingFlagOps(_hiddenCardIds, pending);
      if (!setEquals(local, _hiddenCardIds)) {
        _hiddenCardIds = local;
        unawaited(
          _quietly(
            () => store.replaceHiddenCards(
              local,
              ownerScope: ownerScope,
              canWrite: stillCurrent,
            ),
          ),
        );
      }
      return;
    }
    final next = _applyPendingFlagOps(server, pending);
    // Hides and undos that happened while the reads were in flight win.
    next
      ..addAll(_hiddenCardIds.difference(before))
      ..removeAll(before.difference(_hiddenCardIds))
      ..addAll(_hidesInFlight);
    _hiddenCardIds = next;
    unawaited(
      _quietly(
        () => store.replaceHiddenCards(
          next,
          ownerScope: ownerScope,
          canWrite: stillCurrent,
        ),
      ),
    );
  }

  Future<void> _quietly(Future<void> Function() write) async {
    try {
      await write();
    } catch (_) {
      debugPrint('Recall: hidden-card cache write skipped (non-fatal)');
    }
  }

  // --- Flag notice ---

  String? _flagNotice;
  Timer? _flagNoticeTimer;

  /// A short, inline confirmation for the last flag. It sits in the header,
  /// never over the rating buttons, and fades on its own.
  String? get flagNotice => _flagNotice;

  /// A save the device storage refused before commit. Nothing was stored, so
  /// the action is neither shown nor sent.
  static bool _isRefusedSave(Object error) =>
      error is LocalOutboxWriteException ||
      error is LocalPreferenceWriteNotCommitted;

  /// The pending count when a failed save is in fact stored, or null when it
  /// is not. A refused save never is. A thrown save has unknown commit status,
  /// so native truth decides. A failed read of it proves nothing either way:
  /// the original failure then propagates as [StudyActionUnconfirmedException].
  Future<int?> _savedDespite(
    Object error,
    StackTrace stackTrace,
    Future<int?> Function() settle,
  ) async {
    if (_isRefusedSave(error)) return null;
    try {
      return await settle();
    } catch (_) {
      Error.throwWithStackTrace(
        StudyActionUnconfirmedException(error),
        stackTrace,
      );
    }
  }

  /// A rating whose thrown write could not be checked against native truth.
  ({int cardId, String clientId, String? ownerScope})? _unconfirmedReview;

  /// The flag counterpart of [_unconfirmedReview].
  String? _unconfirmedFlagId;

  /// The id for a rating of [cardId]. The redo of an unconfirmed rating reuses
  /// its id, so a copy already stored stays the only one and the server can
  /// never apply both. Any other unconfirmed rating is settled against native
  /// truth first, so its quarantine cannot block this one.
  Future<String> _reviewClientId(int cardId, String? ownerScope) async {
    final unconfirmed = _unconfirmedReview;
    if (unconfirmed != null) {
      if (unconfirmed.cardId == cardId &&
          unconfirmed.ownerScope == ownerScope) {
        return unconfirmed.clientId;
      }
      try {
        await store.settleUnknownReview(
          unconfirmed.clientId,
          ownerScope: unconfirmed.ownerScope,
        );
        _confirmedReview(unconfirmed.clientId);
      } catch (_) {
        // Still unreadable: keep it, so a later rating can settle it.
      }
    }
    return store.newEventId();
  }

  /// Forget [clientId] once native truth or a definite refusal settled it.
  void _confirmedReview(String clientId) {
    if (_unconfirmedReview?.clientId == clientId) _unconfirmedReview = null;
  }

  /// A fresh flag id, after settling an unconfirmed flag against native truth
  /// so its quarantine cannot block this one. A stored copy simply stays; a
  /// repeated report of a card is harmless, unlike a repeated rating.
  Future<String> _flagClientId() async {
    final unconfirmed = _unconfirmedFlagId;
    if (unconfirmed != null) {
      try {
        await store.settleUnknownFlag(unconfirmed);
        if (_unconfirmedFlagId == unconfirmed) _unconfirmedFlagId = null;
      } catch (_) {
        // Still unreadable: keep it, so a later flag can settle it.
      }
    }
    return store.newEventId();
  }

  /// Report an unsaved action to the caller. A refusal keeps its own type; an
  /// unknown-commit failure that native truth showed absent is wrapped, so
  /// every gesture can absorb both once the notice is shown.
  static Never _throwNotSaved(Object error, StackTrace stackTrace) =>
      Error.throwWithStackTrace(
        _isRefusedSave(error) ? error : StudyActionNotSavedException(error),
        stackTrace,
      );

  void _showFlagNotice(String text) {
    _flagNoticeTimer?.cancel();
    _flagNotice = text;
    _flagNoticeTimer = Timer(const Duration(seconds: 3), _clearFlagNotice);
    notifyListeners();
  }

  void _clearFlagNotice() {
    _flagNoticeTimer?.cancel();
    _flagNoticeTimer = null;
    if (_flagNotice == null) return;
    _flagNotice = null;
    notifyListeners();
  }

  // --- Undo (single-level, session-only) ---

  _UndoRecord? _undo;
  bool _undoInFlight = false;

  /// Whether the most recent rating can still be reverted.
  bool get canUndo => !_rateInFlight && (_undo != null || _hideUndo != null);

  /// True while [undo] is completing. [rate] is blocked for the duration and
  /// the UI hides the undo affordance, so nothing can interleave with the
  /// queue restore.
  bool get undoInFlight => _undoInFlight;

  /// Undo only a review that has never been sent. Once sending begins, even
  /// a lost response can represent a committed review. Remote Undo stays
  /// unavailable until an atomic server contract exists.
  ///
  /// Exclusive: while it runs, [rate] no-ops — otherwise a rating landing
  /// during the awaits below would be rewound over by the queue restore.
  Future<void> undo() => _runStudyAction(_undoCurrentAction);

  Future<void> _undoCurrentAction() async {
    if (_rateInFlight) return;
    final hidden = _hideUndo;
    if (hidden != null && !_undoInFlight) return _undoHide(hidden);
    final u = _undo;
    if (u == null || _undoInFlight) return;
    final session = _state;
    final loadToken = _loadSequence;
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    final countsTowardsGlobalDue = _countsTowardsGlobalDue(u.card);
    bool sessionOwned() =>
        loadToken == _loadSequence &&
        ownerScope == store.activeOwnerScope &&
        ownerId == api.currentUser?.id &&
        (!store.ownerAware ||
            (ownerId != null && store.isActiveOwner(ownerId))) &&
        identical(session.queue, _state.queue);
    bool undoCurrent() => sessionOwned() && session.index == _state.index;

    _undoInFlight = true;
    notifyListeners(); // hide the undo affordance for the duration
    try {
      // A sender closes the Undo slot before its RPC. Wait for an already
      // running sender; never treat a missing acknowledgement as unsent.
      while (_flushTask != null) {
        try {
          await _flushTask;
        } catch (_) {}
        if (!undoCurrent()) return;
      }
      if (!undoCurrent() || !identical(_undo, u)) return;
      _undo = null;
      _interactionGeneration++;
      // The user's local removal remains valid in its original namespace even
      // if a load or account change supersedes its presentation while waiting.
      final result = await store.removeEntry(
        u.clientId,
        ownerScope: ownerScope,
      );
      if (!undoCurrent()) return;
      if (!result.removed) {
        _showFlagNotice('Synced reviews cannot be undone');
        return;
      }
      await _restoreCatchUpState(
        u.catchUp,
        ownerScope: ownerScope,
        canWrite: undoCurrent,
      );
      if (!undoCurrent()) return;
      final reviewed = session.reviewedThisSession;
      final globalDueCount = session.globalDueCount;
      _catchUpSourceQueue = u.catchUpSourceQueue;
      _set(
        _state.copyWith(
          index: u.index,
          showBack: false,
          reviewedThisSession: reviewed > 0 ? reviewed - 1 : 0,
          globalDueCount: !countsTowardsGlobalDue || globalDueCount == null
              ? globalDueCount
              : globalDueCount + 1,
          lastReviewedAt: u.previousLastReviewedAt,
          reviewActivityKnown: u.previousReviewActivityKnown,
          pendingSync: result.remaining,
          catchUp: u.catchUp,
        ),
      );
      // Listeners can synchronously replace the session during notification.
      if (!sessionOwned()) return;
      if (u.card.contentRevalidationPending) {
        unawaited(
          _saveSnapshotQuietly(
            loadToken: loadToken,
            decks: _state.decks,
            queue: u.catchUpSourceQueue,
            globalDueCount: _state.globalDueCount,
            globalDueUpdatedAt: _state.globalDueUpdatedAt,
          ),
        );
      }
      if (!sessionOwned()) return;
      haptics.undo();
    } finally {
      _undoInFlight = false;
      notifyListeners(); // re-enable rating; also covers the early returns
    }
  }

  bool _countsTowardsGlobalDue(ReviewCard card) {
    final due = card.due;
    return _automaticDeckIds.contains(card.deckId) &&
        !card.isNew &&
        due != null &&
        !due.isAfter(clock().toUtc());
  }

  /// Single-flight outbox flush. Concurrent callers (rate + app-resume +
  /// load) join the in-flight run instead of racing replaceOutbox() against
  /// each other, and a call that arrives mid-run schedules one follow-up pass
  /// so entries enqueued after the outbox was read still go out.
  Future<void>? _flushTask;
  bool _flushFollowUp = false;

  Future<void> _flushOutbox() {
    final running = _flushTask;
    if (running != null) {
      _flushFollowUp = true;
      return running;
    }
    final task = _runFlushLoop().whenComplete(() => _flushTask = null);
    _flushTask = task;
    return task;
  }

  Future<void> _runFlushLoop() async {
    do {
      _flushFollowUp = false;
      await _flushOnce();
    } while (_flushFollowUp);
  }

  /// Send queued reviews oldest-first. Stops at the first failure (keeps the
  /// rest queued) so a flaky network never drops a review. Drain captured,
  /// server-acknowledged identities, even when another tab already removed one;
  /// a stale delivered count must never remove a later queued action.
  Future<void> _flushOnce() async {
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    if (!_flushStillOwnsSession(ownerId, ownerScope)) return;
    final pending = await store.outbox(ownerScope: ownerScope);
    if (pending.isEmpty) return;

    final acknowledged = <Map<String, dynamic>>[];
    final uniqueIds = LocalReviewStore.uniqueDeliveryIds(
      pending,
      legacyReviews: true,
    );
    // Ids already marked attempted by the one batch write; null until the
    // first delivery of this pass proves the transport.
    Set<Object>? batchMarked;
    for (var index = 0; index < pending.length; index++) {
      final entry = pending[index];
      if (!_flushStillOwnsSession(ownerId, ownerScope)) break;
      // Older reviews retain their original (card, rating time, device) server
      // deduplication path. Malformed or ambiguous identities stay queued.
      if (!uniqueIds.contains(LocalReviewStore.reviewDeliveryId(entry))) break;
      try {
        final eventId = entry['client_id'];
        // Persist before transport. If Undo already removed it, skip this
        // stale read; otherwise this event remains replayable after any loss.
        if (eventId != null &&
            batchMarked?.contains(eventId) != true &&
            !await store.markReviewAttempted(eventId, ownerScope: ownerScope)) {
          break;
        }
        if (!_flushStillOwnsSession(ownerId, ownerScope)) break;
        final u = _undo;
        if (u != null && u.clientId == eventId) {
          _undo = null;
          _showFlagNotice('Synced reviews cannot be undone');
        }
        await api.applyReview(entry);
        acknowledged.add(entry);
        if (batchMarked == null && index + 1 < pending.length) {
          if (!_flushStillOwnsSession(ownerId, ownerScope)) break;
          batchMarked = await _markRemainingAttempted(
            pending.skip(index + 1),
            uniqueIds,
            ownerScope,
          );
        }
      } catch (_) {
        debugPrint('Recall: review sync deferred (offline?)');
        break;
      }
    }
    // Delivered reviews changed the server's log and due dates.
    if (acknowledged.isNotEmpty) RecallReadCache.of(api).reviewsChanged();
    final remaining = await store.removeAcknowledgedReviews(
      acknowledged,
      ownerScope: ownerScope,
    );
    if (_flushStillOwnsSession(ownerId, ownerScope) &&
        _state.pendingSync != remaining) {
      _set(_state.copyWith(pendingSync: remaining));
    }
  }

  /// Mark the rest of this pass's sendable prefix attempted in one native
  /// write, instead of one whole-outbox rewrite per review. Only an id still
  /// queued comes back; any other id keeps the per-send mark, whose false
  /// result stops the pass. A review this controller can still undo (or that
  /// a rating in flight or a redo of an unconfirmed save can make undoable) is
  /// left out too, so it stays undoable until its own send exactly as before.
  /// A marked review that a later failure leaves unsent is replayed next pass.
  Future<Set<Object>> _markRemainingAttempted(
    Iterable<Map<String, dynamic>> rest,
    Set<Object> uniqueIds,
    String? ownerScope,
  ) {
    final undoable = {
      _undo?.clientId,
      _ratingClientId,
      _unconfirmedReview?.clientId,
    };
    final ids = <Object>[];
    for (final entry in rest) {
      if (!uniqueIds.contains(LocalReviewStore.reviewDeliveryId(entry))) break;
      final id = entry['client_id'];
      if (id != null && !undoable.contains(id)) ids.add(id);
    }
    return store.markReviewsAttempted(ids, ownerScope: ownerScope);
  }

  /// Production local state is owner-aware, so both the API session and the
  /// hashed storage namespace must still name the account that began a flush.
  /// The unscoped branch preserves the deliberately session-free unit harness.
  bool _flushStillOwnsSession(String? ownerId, String? ownerScope) {
    if (ownerScope == null) return !store.ownerAware;
    return ownerId != null &&
        api.currentUser?.id == ownerId &&
        store.activeOwnerScope == ownerScope &&
        store.isActiveOwner(ownerId);
  }

  /// Single-flight flag flush, structurally identical to [_flushOutbox] but on
  /// its own task so it can never interlock with the review flush. A flag
  /// delivery failure breaks only THIS loop; the review flush (and vice versa)
  /// is entirely unaffected — the two share no task, no state, and no lock hold
  /// beyond the store's per-write serialization.
  Future<void>? _flagFlushTask;
  bool _flagFlushFollowUp = false;

  Future<void> _flushFlagOutbox() {
    final running = _flagFlushTask;
    if (running != null) {
      _flagFlushFollowUp = true;
      return running;
    }
    final task = _runFlagFlushLoop().whenComplete(() => _flagFlushTask = null);
    _flagFlushTask = task;
    return task;
  }

  Future<void> _runFlagFlushLoop() async {
    do {
      _flagFlushFollowUp = false;
      await _flushFlagsOnce();
    } while (_flagFlushFollowUp);
  }

  /// Send queued flags oldest-first. Stops at the first failure (keeps the
  /// rest queued) so a missing note_flags table or a flaky network never drops
  /// a flag; only captured, server-acknowledged identities can be removed.
  /// Flags carry no UI badge, so this stays silent and out of the review path.
  Future<void> _flushFlagsOnce() async {
    final ownerScope = store.activeOwnerScope;
    final ownerId = api.currentUser?.id;
    if (!_flushStillOwnsSession(ownerId, ownerScope)) return;
    final pending = await store.flagOutbox(ownerScope: ownerScope);
    if (pending.isEmpty) return;

    final acknowledged = <Map<String, dynamic>>[];
    final uniqueIds = LocalReviewStore.uniqueDeliveryIds(pending);
    for (final entry in pending) {
      if (!_flushStillOwnsSession(ownerId, ownerScope)) break;
      // A legacy or ambiguous identity cannot be safely removed after ACK.
      // Keep it visible for recovery without reapplying it on every flush.
      if (!uniqueIds.contains(entry['client_id'])) break;
      try {
        if (entry['op'] == dismissOp) {
          await api.dismissFlag(
            cardId: (entry['card_id'] as num).toInt(),
            clientEventId: entry['client_id'].toString(),
          );
        } else {
          await api.applyFlag(entry);
        }
        acknowledged.add(entry);
      } catch (_) {
        debugPrint('Recall: flag sync deferred (table missing?)');
        break;
      }
    }
    await store.removeAcknowledgedFlags(acknowledged, ownerScope: ownerScope);
  }

  /// Background work (queue loads, outbox flushes) can finish after the
  /// controller is disposed; notifying then throws in debug builds. Swallow
  /// post-dispose notifications instead — the state update itself is
  /// harmless, there is just nobody left to tell.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _flagNoticeTimer?.cancel();
    _authSub?.cancel();
    prefs?.removeListener(_onPrefsChanged);
    super.dispose();
  }
}

class PendingSyncException implements Exception {
  final int pendingReviews;
  final int pendingFlags;

  const PendingSyncException({
    required this.pendingReviews,
    required this.pendingFlags,
  });

  int get total => pendingReviews + pendingFlags;

  String get userMessage =>
      'Recall is keeping $total pending study ${total == 1 ? 'action' : 'actions'} '
      'on this device. Connect to the internet and try signing out again.';

  @override
  String toString() => userMessage;
}

/// Everything needed to revert the most recent rating: the pre-rating card
/// (the queue's ReviewCard is never mutated by a rating, so it IS the
/// scheduling snapshot — stability/difficulty/due/state/reps/lapses/
/// last_review/cloud_seen), the queue position to return to, the outbox
/// identity of the review, and — once a flush delivers it — the review_log
/// row id to delete. It also keeps the presentation-only catch-up source and
/// progress before the rating so undo cannot consume a daily slot permanently.
class _HideUndoRecord {
  final ReviewCard card;
  final int index;
  final String clientId;

  const _HideUndoRecord({
    required this.card,
    required this.index,
    required this.clientId,
  });
}

class _UndoRecord {
  final String clientId;
  final ReviewCard card;
  final int index;
  final CatchUpView catchUp;
  final List<ReviewCard> catchUpSourceQueue;
  final DateTime? previousLastReviewedAt;
  final bool previousReviewActivityKnown;

  _UndoRecord({
    required this.clientId,
    required this.card,
    required this.index,
    required this.catchUp,
    required this.catchUpSourceQueue,
    required this.previousLastReviewedAt,
    required this.previousReviewActivityKnown,
  });
}

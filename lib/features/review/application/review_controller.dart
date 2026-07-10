import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:supabase_flutter/supabase_flutter.dart' show User, AuthState;

import '../../settings/application/recall_prefs_controller.dart';
import '../../settings/domain/recall_prefs.dart';
import '../data/local_review_store.dart';
import '../data/models.dart';
import '../data/recall_api.dart';
import 'fsrs_engine.dart';
import 'review_state.dart';

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
  final RecallApi api;
  final FsrsEngine engine;
  final LocalReviewStore store;

  /// Wall clock, injectable so tests can drive the elapsed-time stopwatch.
  final DateTime Function() clock;

  /// Study preferences (new-card limit, retention, ordering). Optional so the
  /// existing test harness can construct the controller without one.
  final RecallPrefsController? prefs;
  final Future<void> Function({
    required String email,
    required String password,
  })?
  rememberCredentials;
  final Future<void> Function()? forgetCredentials;
  StreamSubscription<AuthState>? _authSub;

  ReviewController({
    required this.api,
    required this.engine,
    required this.store,
    this.prefs,
    this.rememberCredentials,
    this.forgetCredentials,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    // Supabase emits auth errors (e.g. an offline token refresh) as STREAM
    // errors; without onError they rethrow and can crash the app. Swallow them —
    // an active session going offline should fall back to the cache, not die.
    _authSub = api.onAuthStateChange.listen(
      _onAuthChanged,
      onError: (Object e) =>
          debugPrint('Recall: auth stream error (non-fatal): $e'),
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

    // Only reload once a session-driven load has happened. On the initial
    // startup hydration (prefs.load() before any queue load) the auth-driven
    // load() reads prefs.value directly, so a reload here would be premature.
    final queueAffecting = prev == null || !prev.sameQueueShape(next);
    if (queueAffecting && _sessionLoaded) {
      unawaited(refresh());
    } else {
      notifyListeners();
    }
  }

  ReviewState _state = const ReviewState(loading: false);
  ReviewState get state => _state;

  User? get currentUser => api.currentUser;

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

  void _onAuthChanged(AuthState _) {
    if (api.currentUser == null) {
      // Signed out — drop the session state and show the login gate.
      engine.resetToDefaults();
      _undo = null; // the session (and its undo snapshot) is gone
      _set(const ReviewState(loading: false));
    } else if (_state.queue.isEmpty && !_state.loading) {
      // Signed in (or restored session) — load the queue.
      load();
    } else {
      notifyListeners();
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    _set(_state.copyWith(authSubmitting: true, error: null));
    try {
      await api.signIn(email: email, password: password);
      await _rememberCredentials(email: email, password: password);
      // _onAuthChanged fires on success and loads the queue.
    } catch (e) {
      _set(_state.copyWith(authSubmitting: false, error: _authMessage(e)));
    }
  }

  Future<void> signOut() async {
    await _forgetCredentials();
    // Best-effort: push any queued reviews before dropping the local cache.
    await _flushOutbox();
    // Don't leave one user's snapshot/outbox on disk for the next person on a
    // shared browser — RLS protects the cloud, but the device cache is global.
    await store.clear();
    await api.signOut(); // _onAuthChanged then resets in-memory state
  }

  String _authMessage(Object e) {
    final s = e.toString();
    if (s.contains('Invalid login')) return 'Wrong email or password.';
    return s;
  }

  Future<void> _rememberCredentials({
    required String email,
    required String password,
  }) async {
    try {
      await rememberCredentials?.call(email: email, password: password);
    } catch (e) {
      debugPrint('Recall: credential save failed (non-fatal): $e');
    }
  }

  Future<void> _forgetCredentials() async {
    try {
      await forgetCredentials?.call();
    } catch (e) {
      debugPrint('Recall: credential clear failed (non-fatal): $e');
    }
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

  Future<void> initialize() => load();

  /// True once at least one session-driven load() has run — gates prefs-change
  /// reloads so startup hydration doesn't reload before there's a session.
  bool _sessionLoaded = false;

  Future<void> load({int? deckId, bool keepReviewed = true}) async {
    _sessionLoaded = true;
    final loadToken = ++_loadSequence;
    // Reloading (refresh/deck switch) leaves the session the last rating was
    // made in — its queue position stops meaning anything, so undo expires.
    _undo = null;
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
      ),
    );
    _previewForCardId = null;

    // Cold start: paint the cached snapshot immediately (a card in hand beats
    // a spinner) and let the network fetch below replace it in the background.
    // Not on a deck switch — the snapshot holds the previous filter's queue.
    if (!deckChanged && _state.queue.isEmpty) {
      final snapshot = await store.loadSnapshot();
      if (loadToken != _loadSequence) return; // superseded by a newer load
      if (snapshot != null && snapshot.queue.isNotEmpty) {
        _set(
          _state.copyWith(
            loading: false,
            decks: snapshot.decks,
            queue: snapshot.queue,
            index: 0,
            showBack: false,
            pendingSync: (await store.outbox()).length,
          ),
        );
      }
    }

    // Push queued reviews before fetching so the fetched queue excludes them.
    // The snapshot (if any) is already on screen, so this no longer delays
    // first paint the way it used to.
    await _flushOutbox();

    final generationAtFetch = _interactionGeneration;
    try {
      // Independent round-trips — run them together instead of serially.
      // _refreshFsrsSettings never throws (it falls back to defaults).
      final active = _activePrefs;
      final results = await Future.wait<Object?>([
        _refreshFsrsSettings(),
        api.fetchDecks(),
        api.fetchQueue(
          deckId: _state.deckFilter,
          newLimit: active.newLimitForDeck(_state.deckFilter),
          order: active.newOrder,
        ),
      ]);
      final decks = results[1] as List<DeckRow>;
      final queue = results[2] as List<ReviewCard>;
      final pendingSync = (await store.outbox()).length;
      if (loadToken != _loadSequence) return; // superseded by a newer load
      if (_interactionGeneration == generationAtFetch) {
        _set(
          _state.copyWith(
            loading: false,
            error: null,
            offline: false,
            decks: decks,
            queue: queue,
            index: 0,
            showBack: false,
            pendingSync: pendingSync,
          ),
        );
      } else {
        // The user is already studying the snapshot queue; keep their place
        // and refresh only the metadata. The next load() picks up the rest.
        _set(
          _state.copyWith(
            loading: false,
            error: null,
            offline: false,
            decks: decks,
            pendingSync: pendingSync,
          ),
        );
      }
      _previewForCardId = null;
      // Persist off the critical path — the UI shouldn't wait on storage.
      unawaited(_saveSnapshotQuietly(decks: decks, queue: queue));
    } catch (e) {
      if (loadToken != _loadSequence) return; // superseded by a newer load
      if (_state.queue.isNotEmpty) {
        // Already showing the snapshot (or an active session) — stay on it.
        _set(_state.copyWith(loading: false, error: null, offline: true));
        return;
      }
      final snapshot = await store.loadSnapshot();
      if (snapshot != null) {
        _set(
          _state.copyWith(
            loading: false,
            error: null,
            offline: true,
            decks: snapshot.decks,
            queue: snapshot.queue,
            index: 0,
            showBack: false,
            pendingSync: (await store.outbox()).length,
          ),
        );
      } else {
        _set(_state.copyWith(loading: false, error: e.toString()));
      }
    }
  }

  Future<void> _saveSnapshotQuietly({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
  }) async {
    try {
      await store.saveSnapshot(decks: decks, queue: queue);
    } catch (e) {
      debugPrint('Recall: snapshot save failed (non-fatal): $e');
    }
  }

  Future<void> _refreshFsrsSettings() async {
    try {
      final settings = await api.fetchFsrsSettings();
      if (settings != null) {
        engine.configure(settings);
      } else {
        engine.resetToDefaults();
      }
    } catch (e) {
      engine.resetToDefaults();
      debugPrint('Recall: FSRS settings unavailable, using defaults: $e');
    }
    // Stored study prefs are the source of truth for desired retention; the
    // fsrs_params retention above only fills in when the user hasn't set one.
    final p = prefs;
    if (p != null && p.hasStoredPrefs) {
      engine.setDesiredRetention(p.value.desiredRetention);
      _appliedPrefs = p.value;
    }
  }

  Future<void> refresh() => load(deckId: _state.deckFilter);

  Future<void> selectDeck(int? deckId) =>
      load(deckId: deckId, keepReviewed: false);

  /// Flush queued reviews without reloading the queue — safe on foreground.
  Future<void> syncPending() => _flushOutbox();

  void flip() {
    if (_state.current != null && !_state.showBack) {
      _interactionGeneration++;
      _set(_state.copyWith(showBack: true));
    }
  }

  /// FSRS interval preview for the four rating buttons, cached per card so a
  /// rebuild (e.g. a pending-sync tick) doesn't re-run the scheduler 4×.
  int? _previewForCardId;
  Map<Rating, DateTime> _preview = const {};

  Map<Rating, DateTime> previewCurrent() {
    final card = _state.current;
    if (card == null) return const {};
    if (_previewForCardId != card.id) {
      _preview = engine.preview(card);
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

  Future<void> rate(Rating rating) async {
    final card = _state.current;
    // Blocked while an undo is completing: a rating landing mid-undo would
    // be rewound over by the undo's queue restore — the card would come
    // back as unrated and end up reviewed twice.
    if (card == null || !_state.showBack || _undoInFlight) return;

    _interactionGeneration++;
    final outcome = engine.review(card, rating);
    final shownAt = _cardShownAt;
    final elapsedMs = shownAt == null
        ? null
        : clock().difference(shownAt).inMilliseconds.clamp(0, maxElapsedMs);
    final entry = api.reviewEntry(card, outcome, elapsedMs: elapsedMs);
    // Snapshot everything undo needs BEFORE the rating takes effect. The
    // queue's ReviewCard still holds the pre-rating scheduling state (rating
    // never mutates it), so the card itself is the snapshot.
    // The id is clock-derived so it can never collide with an entry a
    // previous session persisted: the outbox survives restarts (offline
    // flush failures stay queued in shared_preferences), the counter alone
    // would restart at 1 and claim a stale entry.
    final undo = _UndoRecord(
      clientId: '${clock().microsecondsSinceEpoch}-${++_undoSequence}',
      card: card,
      index: _state.index,
    );
    entry['client_id'] = undo.clientId; // outbox identity; never hits the API
    // enqueueReview is local storage (fast, and it must land before the next
    // card so the review can never be lost); it also returns the new pending
    // count so advancing doesn't re-read + re-decode the whole outbox.
    final pending = await store.enqueueReview(entry);
    _undo = undo; // replaces any previous record — undo is single-level
    _set(
      _state.copyWith(
        index: _state.index + 1,
        showBack: false,
        reviewedThisSession: _state.reviewedThisSession + 1,
        pendingSync: pending,
      ),
    );
    // Sync behind the UI — the next card must never wait on the network.
    unawaited(_flushOutbox());
  }

  // --- Undo (single-level, session-only) ---

  _UndoRecord? _undo;
  int _undoSequence = 0;
  bool _undoInFlight = false;

  /// Whether the most recent rating can still be reverted.
  bool get canUndo => _undo != null;

  /// True while [undo] is completing. [rate] is blocked for the duration and
  /// the UI hides the undo affordance, so nothing can interleave with the
  /// queue restore.
  bool get undoInFlight => _undoInFlight;

  /// Revert the most recent rating. If its review is still in the outbox this
  /// is a pure local operation (drop the entry); if it already synced, the
  /// card's pre-rating scheduling state is written back and the review_log
  /// row it produced is deleted (the accepted append-only exception). Either
  /// way the card returns to the front of the queue, question side up, and
  /// the elapsed-time stopwatch restarts.
  ///
  /// Exclusive: while it runs, [rate] no-ops — otherwise a rating landing
  /// during the awaits below would be rewound over by the queue restore.
  Future<void> undo() async {
    final u = _undo;
    if (u == null || _undoInFlight) return;
    _undoInFlight = true;
    notifyListeners(); // hide the undo affordance for the duration
    try {
      // Let any in-flight flush settle first, so the review is definitively
      // either delivered (u.flushed, with its review_log id captured) or
      // still sitting in the outbox — never racing between the two. _undo
      // stays set while waiting: the flush hook needs it to capture the id.
      while (_flushTask != null) {
        try {
          await _flushTask;
        } catch (_) {}
      }
      if (!identical(_undo, u)) return; // superseded/expired while waiting
      _undo = null;
      _interactionGeneration++;

      int? pendingAfterRemove;
      if (!u.flushed) {
        final result = await store.removeEntry(u.clientId);
        pendingAfterRemove = result.remaining;
        if (!result.removed && !u.flushed) {
          // Neither queued nor delivered — should be unreachable with the
          // flush settled above. Bail rather than restore state that never
          // applied.
          debugPrint('Recall: undo skipped — review neither queued nor synced');
          return;
        }
      }
      if (u.flushed) {
        try {
          await api.undoReview({
            ...api.restoreEntry(u.card),
            'review_log_id': u.reviewLogId,
          });
        } catch (e) {
          // Cloud restore failed (offline?). The rating stands; hand the
          // snapshot back so the user can simply tap undo again — unless a
          // newer rating claimed the slot while this call was in flight.
          debugPrint('Recall: undo failed (offline?): $e');
          _undo ??= u;
          return;
        }
      }
      final reviewed = _state.reviewedThisSession;
      _set(
        _state.copyWith(
          index: u.index,
          showBack: false,
          reviewedThisSession: reviewed > 0 ? reviewed - 1 : 0,
          // Read after every await above, so the badge can't be restored to
          // a count captured before a concurrent flush updated it.
          pendingSync: pendingAfterRemove ?? _state.pendingSync,
        ),
      );
    } finally {
      _undoInFlight = false;
      notifyListeners(); // re-enable rating; also covers the early returns
    }
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
  /// rest queued) so a flaky network never drops a review. Only the delivered
  /// prefix is removed from the outbox, so ratings enqueued while this ran
  /// are never clobbered.
  Future<void> _flushOnce() async {
    final pending = await store.outbox();
    if (pending.isEmpty) return;

    var sent = 0;
    for (final entry in pending) {
      try {
        final logId = await api.applyReview(entry);
        sent++;
        // If this delivery was the still-undoable rating, remember the log
        // row it produced so an undo can target exactly that row.
        final u = _undo;
        if (u != null && u.clientId == entry['client_id']) {
          u
            ..flushed = true
            ..reviewLogId = logId;
        }
      } catch (e) {
        debugPrint('Recall: review sync deferred (offline?): $e');
        break;
      }
    }
    final remaining = await store.removeFirst(sent);
    if (_state.pendingSync != remaining) {
      _set(_state.copyWith(pendingSync: remaining));
    }
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
    _authSub?.cancel();
    prefs?.removeListener(_onPrefsChanged);
    super.dispose();
  }
}

/// Everything needed to revert the most recent rating: the pre-rating card
/// (the queue's ReviewCard is never mutated by a rating, so it IS the
/// scheduling snapshot — stability/difficulty/due/state/reps/lapses/
/// last_review/cloud_seen), the queue position to return to, the outbox
/// identity of the review, and — once a flush delivers it — the review_log
/// row id to delete.
class _UndoRecord {
  final String clientId;
  final ReviewCard card;
  final int index;
  bool flushed = false;
  int? reviewLogId;

  _UndoRecord({
    required this.clientId,
    required this.card,
    required this.index,
  });
}

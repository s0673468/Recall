import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:supabase_flutter/supabase_flutter.dart' show User, AuthState;

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
class ReviewController extends ChangeNotifier {
  final RecallApi api;
  final FsrsEngine engine;
  final LocalReviewStore store;
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
    this.rememberCredentials,
    this.forgetCredentials,
  }) {
    // Supabase emits auth errors (e.g. an offline token refresh) as STREAM
    // errors; without onError they rethrow and can crash the app. Swallow them —
    // an active session going offline should fall back to the cache, not die.
    _authSub = api.onAuthStateChange.listen(
      _onAuthChanged,
      onError: (Object e) =>
          debugPrint('Recall: auth stream error (non-fatal): $e'),
    );
  }

  ReviewState _state = const ReviewState(loading: false);
  ReviewState get state => _state;

  User? get currentUser => api.currentUser;

  void _set(ReviewState next) {
    _state = next;
    notifyListeners();
  }

  // --- Auth ---

  void _onAuthChanged(AuthState _) {
    if (api.currentUser == null) {
      // Signed out — drop the session state and show the login gate.
      engine.resetToDefaults();
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

  Future<void> load({int? deckId, bool keepReviewed = true}) async {
    final loadToken = ++_loadSequence;
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
      final results = await Future.wait<Object?>([
        _refreshFsrsSettings(),
        api.fetchDecks(),
        api.fetchQueue(deckId: _state.deckFilter),
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

  Future<void> rate(Rating rating) async {
    final card = _state.current;
    if (card == null || !_state.showBack) return;

    _interactionGeneration++;
    final outcome = engine.review(card, rating);
    // enqueueReview is local storage (fast, and it must land before the next
    // card so the review can never be lost); it also returns the new pending
    // count so advancing doesn't re-read + re-decode the whole outbox.
    final pending = await store.enqueueReview(api.reviewEntry(card, outcome));
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
        await api.applyReview(entry);
        sent++;
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

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

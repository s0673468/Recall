import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:supabase_flutter/supabase_flutter.dart' show User, AuthState;

import '../data/local_review_store.dart';
import '../data/recall_api.dart';
import 'fsrs_engine.dart';
import 'review_state.dart';

/// Owns auth + the study session: gates on the signed-in user, loads the queue
/// (cloud, with an offline cache fallback), flips cards, schedules ratings with
/// FSRS, and persists each review through a durable outbox so a review done
/// offline is never lost.
class ReviewController extends ChangeNotifier {
  final RecallApi api;
  final FsrsEngine engine;
  final LocalReviewStore store;
  StreamSubscription<AuthState>? _authSub;

  ReviewController({
    required this.api,
    required this.engine,
    required this.store,
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
      // _onAuthChanged fires on success and loads the queue.
    } catch (e) {
      _set(_state.copyWith(authSubmitting: false, error: _authMessage(e)));
    }
  }

  Future<void> signOut() async {
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

  // --- Study ---

  Future<void> initialize() => load();

  Future<void> load({int? deckId, bool keepReviewed = true}) async {
    _set(
      _state.copyWith(
        loading: true,
        error: null,
        authSubmitting: false,
        deckFilter: deckId,
        reviewedThisSession: keepReviewed ? null : 0,
      ),
    );

    await _flushOutbox();

    try {
      final decks = await api.fetchDecks();
      final queue = await api.fetchQueue(deckId: _state.deckFilter);
      await store.saveSnapshot(decks: decks, queue: queue);
      _set(
        _state.copyWith(
          loading: false,
          error: null,
          offline: false,
          decks: decks,
          queue: queue,
          index: 0,
          showBack: false,
          pendingSync: (await store.outbox()).length,
        ),
      );
    } catch (e) {
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

  Future<void> refresh() => load(deckId: _state.deckFilter);

  Future<void> selectDeck(int? deckId) =>
      load(deckId: deckId, keepReviewed: false);

  /// Flush queued reviews without reloading the queue — safe on foreground.
  Future<void> syncPending() => _flushOutbox();

  void flip() {
    if (_state.current != null && !_state.showBack) {
      _set(_state.copyWith(showBack: true));
    }
  }

  Map<Rating, DateTime> previewCurrent() {
    final card = _state.current;
    if (card == null) return const {};
    return engine.preview(card);
  }

  Future<void> rate(Rating rating) async {
    final card = _state.current;
    if (card == null || !_state.showBack) return;

    final outcome = engine.review(card, rating);
    await store.enqueueReview(api.reviewEntry(card, outcome));
    _set(
      _state.copyWith(
        index: _state.index + 1,
        showBack: false,
        reviewedThisSession: _state.reviewedThisSession + 1,
        pendingSync: (await store.outbox()).length,
      ),
    );
    await _flushOutbox();
  }

  /// Send queued reviews oldest-first. Stops at the first failure (keeps the
  /// rest queued) so a flaky network never drops a review.
  Future<void> _flushOutbox() async {
    final pending = await store.outbox();
    if (pending.isEmpty) return;

    final remaining = <Map<String, dynamic>>[];
    var failed = false;
    for (final entry in pending) {
      if (failed) {
        remaining.add(entry);
        continue;
      }
      try {
        await api.applyReview(entry);
      } catch (e) {
        debugPrint('Recall: review sync deferred (offline?): $e');
        failed = true;
        remaining.add(entry);
      }
    }
    await store.replaceOutbox(remaining);
    if (_state.pendingSync != remaining.length) {
      _set(_state.copyWith(pendingSync: remaining.length));
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

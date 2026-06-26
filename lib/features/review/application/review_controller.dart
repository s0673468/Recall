import 'package:flutter/foundation.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import '../data/local_review_store.dart';
import '../data/recall_api.dart';
import 'fsrs_engine.dart';
import 'review_state.dart';

/// Owns the study session: loads the queue (cloud, with an offline cache
/// fallback), flips cards, schedules ratings with FSRS, and persists each review
/// through a durable outbox so a review done offline is never lost.
class ReviewController extends ChangeNotifier {
  final RecallApi api;
  final FsrsEngine engine;
  final LocalReviewStore store;

  ReviewController({
    required this.api,
    required this.engine,
    required this.store,
  });

  ReviewState _state = const ReviewState();
  ReviewState get state => _state;

  void _set(ReviewState next) {
    _state = next;
    notifyListeners();
  }

  Future<void> initialize() => load();

  Future<void> load({int? deckId, bool keepReviewed = true}) async {
    _set(
      _state.copyWith(
        loading: true,
        error: null,
        deckFilter: deckId,
        reviewedThisSession: keepReviewed ? null : 0,
      ),
    );

    // Best-effort: push anything queued from a previous offline session first.
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
      // Offline (or the backend is unreachable): fall back to the cached
      // snapshot so the user can keep reviewing.
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

  /// Flush queued reviews without reloading the queue — safe to call on
  /// app-foreground so an offline session syncs without losing your place.
  Future<void> syncPending() => _flushOutbox();

  Future<void> selectDeck(int? deckId) =>
      load(deckId: deckId, keepReviewed: false);

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
    // Durably record the review, then advance the UI immediately.
    await store.enqueueReview(api.reviewEntry(card, outcome));
    _set(
      _state.copyWith(
        index: _state.index + 1,
        showBack: false,
        reviewedThisSession: _state.reviewedThisSession + 1,
        pendingSync: (await store.outbox()).length,
      ),
    );

    // Try to sync in the background; failures stay queued for next time.
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
}

import 'dart:collection';

import '../data/models.dart';
import 'backlog_catch_up.dart';

const Object _unset = Object();

class ReviewState {
  final bool loading;
  final String? error;
  final List<ReviewCard> queue;
  final int index;
  final bool showBack;
  final List<DeckRow> decks;
  final int? deckFilter;
  final int reviewedThisSession;
  final int reviewedToday;
  final bool offline;

  /// With [offline] or [error], the last load failed because Recall's server
  /// answered with an error (permission, 5xx, missing function), not because
  /// the connection failed. The saved-queue behaviour is the same; only the
  /// wording differs.
  final bool serverError;
  final int pendingSync;

  /// Queued reviews the server permanently refused. They are still counted in
  /// [pendingSync] and kept on the device, but no longer hold the rest.
  final int syncErrors;
  final bool authSubmitting;
  final int? globalDueCount;
  final DateTime? globalDueUpdatedAt;
  final DateTime? lastReviewedAt;
  final bool reviewActivityKnown;

  /// Presentation-only backlog catch-up metadata. It never represents a
  /// scheduling write or a second source of truth for due dates.
  final CatchUpView catchUp;

  /// True when the last "Keep going" fetch came back empty — there is nothing
  /// due within the look-ahead window and no unseen cards left, so the done
  /// screen stops offering the button until the next normal load.
  final bool aheadExhausted;

  const ReviewState({
    this.loading = true,
    this.error,
    this.queue = const [],
    this.index = 0,
    this.showBack = false,
    this.decks = const [],
    this.deckFilter,
    this.reviewedThisSession = 0,
    this.reviewedToday = 0,
    this.offline = false,
    this.serverError = false,
    this.pendingSync = 0,
    this.syncErrors = 0,
    this.authSubmitting = false,
    this.globalDueCount,
    this.globalDueUpdatedAt,
    this.catchUp = const CatchUpView(),
    this.lastReviewedAt,
    this.reviewActivityKnown = false,
    this.aheadExhausted = false,
  });

  ReviewCard? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
  int get remaining => (queue.length - index).clamp(0, queue.length);
  int get dueRemaining => queue is _CountedReviewQueue
      ? (queue as _CountedReviewQueue).remainingFrom(index) - newRemaining
      : queue.skip(index).where((c) => !c.isNew).length;
  int get newRemaining => queue is _CountedReviewQueue
      ? (queue as _CountedReviewQueue).newFrom(index)
      : queue.skip(index).where((c) => c.isNew).length;
  bool get isDone => !loading && error == null && current == null;

  ReviewState copyWith({
    bool? loading,
    Object? error = _unset,
    List<ReviewCard>? queue,
    int? index,
    bool? showBack,
    List<DeckRow>? decks,
    Object? deckFilter = _unset,
    int? reviewedThisSession,
    int? reviewedToday,
    bool? offline,
    bool? serverError,
    int? pendingSync,
    int? syncErrors,
    bool? authSubmitting,
    Object? globalDueCount = _unset,
    Object? globalDueUpdatedAt = _unset,
    CatchUpView? catchUp,
    Object? lastReviewedAt = _unset,
    bool? reviewActivityKnown,
    bool? aheadExhausted,
  }) {
    return ReviewState(
      loading: loading ?? this.loading,
      error: identical(error, _unset) ? this.error : error as String?,
      queue: queue == null ? this.queue : _CountedReviewQueue.of(queue),
      index: index ?? this.index,
      showBack: showBack ?? this.showBack,
      decks: decks ?? this.decks,
      deckFilter: identical(deckFilter, _unset)
          ? this.deckFilter
          : deckFilter as int?,
      reviewedThisSession: reviewedThisSession ?? this.reviewedThisSession,
      reviewedToday: reviewedToday ?? this.reviewedToday,
      offline: offline ?? this.offline,
      serverError: serverError ?? this.serverError,
      pendingSync: pendingSync ?? this.pendingSync,
      syncErrors: syncErrors ?? this.syncErrors,
      authSubmitting: authSubmitting ?? this.authSubmitting,
      globalDueCount: identical(globalDueCount, _unset)
          ? this.globalDueCount
          : globalDueCount as int?,
      globalDueUpdatedAt: identical(globalDueUpdatedAt, _unset)
          ? this.globalDueUpdatedAt
          : globalDueUpdatedAt as DateTime?,
      catchUp: catchUp ?? this.catchUp,
      lastReviewedAt: identical(lastReviewedAt, _unset)
          ? this.lastReviewedAt
          : lastReviewedAt as DateTime?,
      reviewActivityKnown: reviewActivityKnown ?? this.reviewActivityKnown,
      aheadExhausted: aheadExhausted ?? this.aheadExhausted,
    );
  }
}

/// Published queues cannot change under their counts. Build the prefix once,
/// on the first counter read, and share it across flips, sync ticks, grading
/// and Undo. Replacing a queue starts a new index; metadata copies reuse it.
class _CountedReviewQueue extends UnmodifiableListView<ReviewCard> {
  _CountedReviewQueue._(super.source);

  static _CountedReviewQueue of(List<ReviewCard> source) =>
      source is _CountedReviewQueue
      ? source
      : _CountedReviewQueue._(List<ReviewCard>.unmodifiable(source));

  late final List<int> _newPrefix = _countNew();

  List<int> _countNew() {
    final prefix = List<int>.filled(length + 1, 0);
    for (var i = 0; i < length; i++) {
      prefix[i + 1] = prefix[i] + (this[i].isNew ? 1 : 0);
    }
    return prefix;
  }

  int remainingFrom(int index) {
    RangeError.checkNotNegative(index, 'index');
    return index >= length ? 0 : length - index;
  }

  int newFrom(int index) {
    RangeError.checkNotNegative(index, 'index');
    return index >= length ? 0 : _newPrefix[length] - _newPrefix[index];
  }
}

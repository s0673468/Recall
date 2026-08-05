import '../data/models.dart';

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
  final bool offline;
  final int pendingSync;
  final bool authSubmitting;
  final int? globalDueCount;
  final DateTime? globalDueUpdatedAt;
  final DateTime? lastReviewedAt;
  final bool reviewActivityKnown;

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
    this.offline = false,
    this.pendingSync = 0,
    this.authSubmitting = false,
    this.globalDueCount,
    this.globalDueUpdatedAt,
    this.lastReviewedAt,
    this.reviewActivityKnown = false,
    this.aheadExhausted = false,
  });

  ReviewCard? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
  int get remaining => (queue.length - index).clamp(0, queue.length);
  int get dueRemaining => queue.skip(index).where((c) => !c.isNew).length;
  int get newRemaining => queue.skip(index).where((c) => c.isNew).length;
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
    bool? offline,
    int? pendingSync,
    bool? authSubmitting,
    Object? globalDueCount = _unset,
    Object? globalDueUpdatedAt = _unset,
    Object? lastReviewedAt = _unset,
    bool? reviewActivityKnown,
    bool? aheadExhausted,
  }) {
    return ReviewState(
      loading: loading ?? this.loading,
      error: identical(error, _unset) ? this.error : error as String?,
      queue: queue ?? this.queue,
      index: index ?? this.index,
      showBack: showBack ?? this.showBack,
      decks: decks ?? this.decks,
      deckFilter: identical(deckFilter, _unset)
          ? this.deckFilter
          : deckFilter as int?,
      reviewedThisSession: reviewedThisSession ?? this.reviewedThisSession,
      offline: offline ?? this.offline,
      pendingSync: pendingSync ?? this.pendingSync,
      authSubmitting: authSubmitting ?? this.authSubmitting,
      globalDueCount: identical(globalDueCount, _unset)
          ? this.globalDueCount
          : globalDueCount as int?,
      globalDueUpdatedAt: identical(globalDueUpdatedAt, _unset)
          ? this.globalDueUpdatedAt
          : globalDueUpdatedAt as DateTime?,
      lastReviewedAt: identical(lastReviewedAt, _unset)
          ? this.lastReviewedAt
          : lastReviewedAt as DateTime?,
      reviewActivityKnown: reviewActivityKnown ?? this.reviewActivityKnown,
      aheadExhausted: aheadExhausted ?? this.aheadExhausted,
    );
  }
}

/// Replaying one queued review against the server, safely, when more than one
/// device is studying the same collection.
///
/// The outbox is at-least-once and per-device: two phones can each rate the
/// same card while offline and then flush in either order. The naive write —
/// "PATCH the cards row with whatever this device computed" — makes the last
/// flush win outright, so the earlier-syncing device's scheduling *and* its
/// `reps`/`lapses` are silently overwritten by a device that computed its
/// counters from a stale local snapshot.
///
/// This module holds the whole conflict policy as plain, transport-free logic
/// so it can be exercised against a modelled server in tests:
///
///  - **Scheduling is newest-review-wins.** The event carrying the later
///    `last_review` owns `stability`/`difficulty`/`due`/`state`/`last_review`.
///    A replay that arrives late but happened *earlier* leaves those alone.
///  - **Counters accumulate from server state.** `reps`/`lapses` are always
///    `server + 1` / `server + (lapsed ? 1 : 0)`, never the absolute values the
///    device computed off its own snapshot. Both reviews genuinely happened, so
///    both are counted regardless of which one wins the scheduling.
///  - **The write is compare-and-swap on `reps`.** Every applied review
///    increments `reps` by exactly one, so it doubles as the row version: the
///    update only lands if the row still carries the `reps` this replay read.
///    A lost race re-reads and re-merges rather than clobbering.
///
/// Duplicate suppression (the same review replayed twice) is a separate
/// concern, handled by the caller through the `client_event_id` ledger before
/// any of this runs.
library;

/// The server-side card fields the merge needs. `reps` is nullable because the
/// compare-and-swap predicate has to distinguish "reps is 0" from "reps IS
/// NULL" — those are different rows to a SQL `=` comparison.
class CardSyncState {
  final int? reps;
  final int? lapses;
  final DateTime? lastReview;

  const CardSyncState({
    required this.reps,
    required this.lapses,
    required this.lastReview,
  });

  factory CardSyncState.fromRow(Map<String, dynamic> row) => CardSyncState(
    reps: (row['reps'] as num?)?.toInt(),
    lapses: (row['lapses'] as num?)?.toInt(),
    lastReview: row['last_review'] == null
        ? null
        : DateTime.tryParse(row['last_review'] as String)?.toUtc(),
  );
}

/// The narrow server surface [applyMergedReview] drives. Implemented once over
/// Supabase (`RecallApi`) and once in-memory (the test server model), so both
/// run the same replay algorithm.
abstract class ReviewReplayGateway {
  /// Current scheduling state of the card, or null when the row is gone
  /// (deleted server-side while the review sat in the outbox).
  Future<CardSyncState?> readCardState(int cardId);

  /// Apply [values] to the card only if its `reps` still equals
  /// [expectedReps] (null meaning the column is SQL NULL). Returns the number
  /// of rows actually updated — 0 means another device won the race.
  Future<int> updateCardWhereReps(
    int cardId, {
    required int? expectedReps,
    required Map<String, dynamic> values,
  });
}

/// Raised when [applyMergedReview] keeps losing the compare-and-swap race. The
/// review stays in the caller's outbox and is retried on the next flush, so an
/// unluckily contended card defers rather than corrupts.
class ReviewReplayConflict implements Exception {
  final int cardId;
  final int attempts;

  const ReviewReplayConflict(this.cardId, this.attempts);

  @override
  String toString() =>
      'Recall could not apply a review to card $cardId after $attempts '
      'attempts — another device kept updating it first.';
}

/// How many compare-and-swap rounds to try before deferring the review. Real
/// contention here is two of one person's devices flushing at once, so losing
/// four times in a row means something else is wrong.
const int reviewReplayMaxAttempts = 4;

/// Whether this review counted as a lapse — the FSRS `lapses` increment.
///
/// New entries carry an explicit `lapsed` flag. Entries queued by an older
/// build predate it, so fall back to the transition that defines a lapse:
/// FSRS only counts one for `Again` on a review/relearning card, and that is
/// exactly the rating that lands the card in state 3 (relearning).
bool reviewLapsed(Map<String, dynamic> entry) {
  final flag = entry['lapsed'];
  if (flag is bool) return flag;
  return (entry['rating'] as num?)?.toInt() == 1 &&
      (entry['state'] as num?)?.toInt() == 3;
}

/// The columns to write for [entry] given the card's current [server] state.
///
/// Counters always advance from the server's values. Scheduling is only
/// overwritten when this review is genuinely newer than what the row already
/// records, so a late-flushing offline review counts its rep without dragging
/// the card back to an older due date.
Map<String, dynamic> mergeReviewIntoCard({
  required CardSyncState server,
  required Map<String, dynamic> entry,
}) {
  final values = <String, dynamic>{
    'reps': (server.reps ?? 0) + 1,
    'lapses': (server.lapses ?? 0) + (reviewLapsed(entry) ? 1 : 0),
    'cloud_seen': true,
  };

  final serverAt = server.lastReview;
  final eventAt = entry['last_review'] == null
      ? null
      : DateTime.tryParse(entry['last_review'] as String)?.toUtc();
  final schedulingWins =
      serverAt == null || (eventAt != null && eventAt.isAfter(serverAt));
  if (!schedulingWins) return values;

  return {
    ...values,
    'stability': entry['stability'],
    'difficulty': entry['difficulty'],
    'due': entry['due'],
    'state': entry['state'],
    'last_review': entry['last_review'],
  };
}

/// Merge one review into its card through [gateway], retrying the
/// compare-and-swap while another device keeps winning the row.
///
/// Returns normally when the card is gone server-side: the row was deleted
/// while the review waited in the outbox, and the caller should still append
/// the log row so the review history stays complete.
Future<void> applyMergedReview(
  ReviewReplayGateway gateway,
  Map<String, dynamic> entry, {
  int maxAttempts = reviewReplayMaxAttempts,
}) async {
  final cardId = (entry['card_id'] as num).toInt();
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final server = await gateway.readCardState(cardId);
    if (server == null) return;
    final updated = await gateway.updateCardWhereReps(
      cardId,
      expectedReps: server.reps,
      values: mergeReviewIntoCard(server: server, entry: entry),
    );
    if (updated > 0) return;
  }
  throw ReviewReplayConflict(cardId, maxAttempts);
}

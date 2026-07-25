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

  /// The row carries a `last_review` we could not parse.
  ///
  /// Distinct from `lastReview == null`, which means the column is SQL NULL —
  /// a card nobody has reviewed yet, where the incoming review is unambiguously
  /// newer. An unreadable value instead means the card *has* been reviewed and
  /// we cannot tell when, so the merge has to fail closed rather than assume
  /// it is free to overwrite the scheduling.
  final bool lastReviewUnreadable;

  const CardSyncState({
    required this.reps,
    required this.lapses,
    required this.lastReview,
    this.lastReviewUnreadable = false,
  });

  factory CardSyncState.fromRow(Map<String, dynamic> row) {
    final raw = row['last_review'];
    final parsed = raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    return CardSyncState(
      reps: (row['reps'] as num?)?.toInt(),
      lapses: (row['lapses'] as num?)?.toInt(),
      lastReview: parsed,
      lastReviewUnreadable: raw != null && parsed == null,
    );
  }
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

/// The columns to write for [entry] given the card's current [server] state,
/// or an **empty map** when the row already reflects this review and nothing
/// needs writing.
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

  // We cannot order this review against a timestamp we cannot read, and the
  // row holds real scheduling from some earlier write. Write nothing at all:
  // a counters-only patch here would leave `last_review` untouched, so the
  // equality check below could never recognise the merge on a later retry and
  // every replay of this entry would add another phantom rep.
  if (server.lastReviewUnreadable) return const {};

  final serverAt = server.lastReview;
  final eventAt = entry['last_review'] == null
      ? null
      : DateTime.tryParse(entry['last_review'] as String)?.toUtc();

  // The row already carries this review's own timestamp, so a previous attempt
  // merged it and then failed before the log row landed. Counters are derived
  // from server state now, so repeating the merge would inflate `reps`; the
  // caller only needs to finish appending the log.
  //
  // This is a heuristic, not true idempotency — see "Replay is not fully
  // idempotent" in the README. It cannot tell our own partial apply from a
  // second device that rated at the identical instant, so that (vanishingly
  // rare) tie loses a rep. Traded knowingly against retry double-counting,
  // which a flaky mobile connection makes far more likely.
  if (eventAt != null &&
      serverAt != null &&
      serverAt.isAtSameMomentAs(eventAt)) {
    return const {};
  }

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
/// the log row so the review history stays complete. Also returns normally
/// when the merge is a no-op because a previous attempt already applied it.
///
/// The card is merged *before* the log row is appended. That ordering is
/// deliberate: if this throws, no log row exists, so the next flush re-reads
/// and retries the whole apply cleanly. The reverse order would let a failure
/// between the two writes strand a logged review whose counters never land,
/// because the caller's `client_event_id` probe would then short-circuit it.
Future<void> applyMergedReview(
  ReviewReplayGateway gateway,
  Map<String, dynamic> entry, {
  int maxAttempts = reviewReplayMaxAttempts,
}) async {
  final cardId = (entry['card_id'] as num).toInt();
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final server = await gateway.readCardState(cardId);
    if (server == null) return;
    final values = mergeReviewIntoCard(server: server, entry: entry);
    if (values.isEmpty) return; // already applied by an earlier attempt
    final updated = await gateway.updateCardWhereReps(
      cardId,
      expectedReps: server.reps,
      values: values,
    );
    if (updated > 0) return;
  }
  throw ReviewReplayConflict(cardId, maxAttempts);
}

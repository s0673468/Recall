# Material content revalidation

Recall gives a materially rewritten, previously studied card one near-term
validation review without resetting its FSRS history.

## Authoring contract

The desktop revision pipeline owns the note tag:

```text
content_revalidate::YYYYMMDDTHHMMSSZ
```

The timestamp is the UTC publication time of the material revision. A material
edit replaces any older marker. A wording-only edit leaves the marker unchanged
and must not create one. New cards do not need a marker because their ordinary
new-card state already puts them into study.

Recall accepts only the exact compact UTC format. Invalid and lookalike tags are
ignored.

## Queue and acknowledgement

On each cloud queue load, Recall reads a bounded batch of studied cards carrying
the marker. It checks the append-only `review_log` for a later successful rating:

- Again does not acknowledge the revised content.
- Hard, Good, or Easy after the marker acknowledges it.
- A successful rating before the marker does not acknowledge a later revision.

At most 20 pending cards are prepended to the ordinary queue. The marker scan is
paged and capped at 5,000 marked cards per load. Already acknowledged cards are
skipped, so later pending cards naturally move into the batch.

The read path writes no scheduling data. When the learner rates a validation
card, Recall performs its normal FSRS review. Existing stability, difficulty,
repetitions, lapses, state, and review history are inputs to that review; nothing
is reset or reseeded.

## Offline and replay behavior

The normal durable review outbox remains the only outbound write buffer.
Pending outbox card IDs are removed from both cloud and cached queues, so an
offline retry cannot offer the same card twice. A successful validation also
prunes the disposable snapshot immediately. Undo restores the snapshot entry.

Server replay remains idempotent through `client_event_id`. Once the review-log
row is readable, the next queue load independently derives whether the current
marker is acknowledged. No mutable `validated` flag or second source of truth is
introduced.

If the marker or review-log read is unavailable, Recall serves its ordinary
due/new queue and defers the priority lane. This feature does not make studying
depend on the revision pipeline.

## Convergence checks

A run is converged when:

1. every material edit has exactly one current timestamped marker;
2. wording-only edits have not advanced a marker;
3. each acknowledged marker has at least one later review-log row with rating
   2, 3, or 4;
4. `fetchContentRevalidationQueue` returns only the remaining unacknowledged
   cards, capped at 20;
5. no queue-discovery request writes a card, note, or review-log row.

The focused regression suite is `test/content_revalidation_test.dart`, with
offline/outbox integration coverage in `test/recall_test.dart`.

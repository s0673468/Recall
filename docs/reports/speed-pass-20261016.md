# Recall speed pass — 2026-10-16

Technical only: no card, deck, article or seed content changed.

## What was looked at

- **App start and opening a session** (`ReviewController.load`): the snapshot
  paint, outbox flush, then a parallel fan-out of decks, queue, global due
  count, recent reviews, hidden cards and FSRS settings.
- **Rating a card** (`_rateVisibleCard`): the local outbox append, catch-up
  progress and the background flush.
- **Sync** (`_flushOnce`, `LocalReviewStore`): oldest-first delivery that stops
  at the first failure and retries on the next trigger. It does not loop, so
  backoff is not an issue.

## What was fixed

`RecallApi.fetchQueue` awaited the "new cards introduced today" history
(today's `review_log` pages, then prior-history batches) **before starting** the
due-card query. Only the new-card page limit depends on that count. The due
cards and the revalidation lane do not. Every queue load (cold start, foreground
refresh, deck switch) therefore paid for the history chain and the due paging
one after the other.

Due paging now starts in the same wave as the history read. Only the new-card
page waits for the introduction count, so its limit is computed exactly as
before. The result is identical; the queue costs the longer chain instead of
the sum of both. If the history read fails, the queue read still fails as
before, and no unhandled error escapes from the concurrent due read.

### Measurement

`test/recall_api_queue_round_trips_test.dart` drives the real `RecallApi`
against a fake PostgREST server. All in-flight requests are answered together
in one "round", so the round count equals the serial network round trips on the
critical path. Results before and after the fix (before = the same tests run
against the previous `recall_api.dart`):

| Scenario | Before | After |
| --- | --- | --- |
| Fresh day, no reviews yet, small queue | 3 | 2 |
| Day with reviews (history 4 trips), one due page | 6 | 5 |
| No reviews today, 1,500-card backlog (4 due pages) | 5 | 4 |

That is one round trip saved per queue fetch, before the first fresh card can
appear. On a mobile link with an 80–150 ms round trip, that is roughly
0.1 s on every cold start and refresh. The largest download, the first
500-row due page, now overlaps the small history reads instead of following
them. The request count and the request URLs are unchanged.

Reproduce:

```sh
./tool/flutterw test --no-pub test/recall_api_queue_round_trips_test.dart
```

## Next candidates (small follow-up tickets)

1. **Read only the needed keys from native preferences.**
   `LocalReviewPreferences.readSnapshot` calls the platform `getAll()`. That
   sends every `flutter.*` preference across the platform channel and decodes
   it, including the full study-queue snapshots with card HTML. `LocalReviewStore`
   does this for almost every operation: about 4–5 times per online rating
   (enqueue, catch-up read when active, then flush: outbox read, mark-attempted,
   remove-acknowledged). The Android and web plugins filter
   `getAllWithParameters(PreferencesFilter(allowList: …))` natively, so a keyed
   read would transfer only the outbox or progress value.
   *Blocker:* eight existing tests inject faults or gates by overriding
   `getAll()` on their fake store. Switching would silently bypass those
   injections. The ticket must authorize updating those fakes to also override
   `getAllWithParameters`. Measure the bytes returned per rating with a counting
   fake platform.
2. **Avoid a full outbox rewrite per delivered review.** `_flushOnce` calls
   `markReviewAttempted` before each send. Each call reads the native snapshot
   (see 1), decodes the whole outbox, re-encodes it and writes it back.
   Draining N reviews after an offline session costs O(N²) bytes of JSON and N
   native writes. One option is to mark a bounded batch attempted in one write.
   That changes Undo eligibility timing (#91, #102), so it needs its own
   reliability tests for the Undo window and for a failure part-way through
   the batch.
3. **Remove the remaining serial steps in `ReviewController.load`.** With a
   deck selected, the queue fetch still waits for `fetchDecks()`, even though
   `includedDeckIds` is only used for the all-decks stream. That costs one
   round trip when opening a deck session. Separately, when the fresh hidden
   set differs from the cached one, the second `fetchQueue` runs after the
   whole fan-out finishes. A round-trip test like the one above can pin both.

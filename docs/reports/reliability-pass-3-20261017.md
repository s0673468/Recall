# Reliability pass 3 — 2026-10-17

Base: `main` at `4e1751e` (#144). Android and web only. No card, deck or
article content changed. The fix is in the shared `ReviewController`, so it
behaves the same on Android and the web.

I started from pass 2's "top 3 next". While checking item 2 (a silent network
drop in the middle of a session), I found a larger problem underneath it: a
review send that hangs, rather than fails, could freeze Undo and rating.

## What was checked

| Area | Where | Result |
|---|---|---|
| Pass 2 next 1: migration 008 | `scripts/supabase/migrations/008_*` | Not done. This is a production Recall write and needs German's approval. The code still works without 008 (parked reviews, #140). |
| Pass 2 next 2: silent drop, failing sends | `_flushOnce`, `_rate`, study header | Small harm only. When a send *fails* quickly, only the oldest rating's Undo is closed, which is what happens on every online rating anyway. The header shows "N syncing" instead of "Offline". Android's resume and validated-network callback and the browser's 1-minute timer all retry, so the queue drains on reconnect. Left as next step 2. |
| Silent drop, **hanging** sends | `_flushOnce`, `undo`, `keepGoing`, `load`, `_runSignOut` | **Gap found and fixed** (below). |
| Transport limits | `postgrest-2.9.1` `postgrest_builder.dart`, `Supabase.initialize` | `requestTimeout` defaults to null, and `apply_review` is a POST, which the client never retries. Recall sets no timeout. Nothing limits how long one send can take. |
| Replay safety | `006_apply_review_rpc.sql`, `008_*.sql` | `insert … on conflict (card_id, client_event_id) do nothing`, then return the existing id. A replay, or two copies racing, logs once and merges once. |
| Flag sends | `_flushFlagsOnce`, `applyFlag`, `dismissFlag` | Same lack of a timeout, but a hung flag send does not block Undo or rating. It can still hold sign-out. See next step 3. |

## The gap: one hung send froze Undo and rating

A connection can die without failing: a dead zone where Wi-Fi or mobile data
still looks connected, or a pooled socket the network dropped. A request on it
can stay open for minutes; on Android that is up to about 15 minutes of TCP
retries. Several study actions wait for the running send:

- **Undo** waits for any running send before removing its review. That is
  deliberate: a review that has been sent might be on the server. While Undo
  waits, `undoInFlight` is set, so every rating tap is ignored.
- **Keep going**, **Reload**/deck switch and **sign-out** all flush first.

Before this fix:

1. German studies on the train. The signal goes but the phone still shows a
   connection. He rates card 1, and its send hangs.
2. He mis-taps card 2 and presses Undo. The Undo button disappears, and the
   rating buttons stop responding. Nothing happens until the hung request
   finally errors, which can take minutes.
3. On the done screen, Keep going spins for the same time, and Sign out does
   not return.

**Fix** (`_flushOnce`, `_runFlushLoop`):

- Each review send is bounded by `reviewSendTimeout` (15 seconds). After that,
  the pass treats it like any transport failure: it stops, and the review
  stays queued. It was already marked attempted before the send, so it is
  replayed later and the server dedupes it on `client_event_id`, even if the
  abandoned request reaches the server after all.
- After a timed-out pass, the flush loop does not run its follow-up pass.
  That pass would only wait out a second timeout on the same dead connection
  while Undo is still waiting. The next rating, resume, reconnect or browser
  timer retries instead. A quick failure keeps the old follow-up behaviour.
- A legacy queued review without a `client_id` keeps the old unbounded wait.
  Its client-side replay path is not deduped on the server, so it must not
  race a second copy.

With the fix, Undo during a dead connection waits at most one bound and then
restores the card. Keep going and sign-out settle with their existing offline
outcomes ("needs a connection" and `PendingSyncException`).

**Tests:** `test/review_send_timeout_test.dart`, using a 50 ms bound injected
through the new constructor parameter:

- *Undo during a hung send returns after the bound.* Undo restores card 2,
  only card 1 stays queued, exactly one send was attempted, and the next
  rating works.
- *A timed-out send is replayed once, never applied twice.* The abandoned
  request lands later, the replay is acknowledged by the existing log row,
  and the server has one log row for the card.
- *Keep going settles after a hung send instead of spinning.*
- *Sign-out during a hung send refuses and keeps the review.*
- *A send that answers within the bound still delivers.* This is the control
  case.

Before the fix, the Undo, replay and Keep going tests failed on their 5-second
guard (`Undo waited on a send that never returns`, and so on). The control
test passed. I added the sign-out test afterwards. With only the timeout
removed, it failed the same way (`Sign-out waited on a send that never
returns`), as did the other three. As a mutation check, I removed only the
follow-up `break`. The Undo test then failed on `Expected: <1> Actual: <2>`
send attempts.

## Top 3 next

1. **Apply migration 008 in production (needs German's approval: Recall,
   production write).** This is unchanged from pass 2. Until it is applied, a
   review for a hard-deleted card is parked again after every restart. It shows
   "1 couldn't sync" and makes sign-out refuse. Back up `review_log` and
   `cards`, apply `008_apply_review_missing_card.sql`, then run
   `verify_apply_review.sql` and `verify_schema.sql`.
2. **Mark the session offline after a transport failure in `_flushOnce`.**
   Now that a hung send also ends as a failure (a `TimeoutException`), this
   would make the header honest ("Offline · N waiting" instead of
   "N syncing"). It would also stop each later rating starting another doomed
   send. #137's delivery path already clears it on reconnect, and Android and
   web both have reconnect triggers. The cost is that a single transient
   failure holds ratings locally until the next resume, reconnect or 1-minute
   browser tick. Reword "Synced reviews cannot be undone" to "Sent reviews
   cannot be undone" at the same time. Pass 2's serverError item (stale label
   after Keep going or reconnect) belongs in the same change.
3. **Bound the flag send and the load's network reads the same way.**
   `_flushFlagsOnce` has no bound, so a hung flag send can still hold
   sign-out. `applyFlag` upserts on `(card_id, client_event_id)` and
   `dismissFlag` is a conditional update, so both are safe to replay. Load and
   Keep going fetches (`fetchQueue`, `fetchAheadQueue`) can also hang, which
   leaves an empty-cache cold start on its spinner. A Supabase-level
   `requestTimeout` would cover the reads, but it changes every request and
   their retries, so it needs its own pass.

## Verification

- `./tool/flutterw analyze`: `No issues found!`
- `./tool/flutterw test`: `All tests passed!` with 1095 passed and 32
  skipped. Pass 2 recorded 1090 passed and 32 skipped on its head; the five
  additions are the new tests.
- `./tool/flutterw test test/review_send_timeout_test.dart`: before the fix,
  1 passed and 3 failed (4 tests at that point). With the timeout removed
  again later, 1 passed and 4 failed. After the fix, 5 passed.

These are Flutter controller tests with a fake API whose send never returns.
They do not exercise a real device on a dead network or a deployed Supabase
project.

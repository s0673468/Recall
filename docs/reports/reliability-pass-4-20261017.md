# Reliability pass 4 — 2026-10-17

Base: `main` at `e38fbe6` (#145). Android and web only. No card, deck or
article content changed. The fix is in the shared `ReviewController`, so it
behaves the same on Android and the web. Migration 008 has been applied in
production since today (Oct 17).

I started from pass 3's "top 3 next". While checking item 3 (bound the flag
send), I found that pass 3's table was wrong: it said "a hung flag send does
not block Undo or rating". It does. The Undo of a hide waits for the flag
send, and rating is locked while that Undo runs. The same hung send also
stopped both platforms' automatic sync from retrying reviews. That is the
same harm pass 3 fixed for review sends, so I fixed it before item 2.

## What was checked

| Area | Where | Result |
|---|---|---|
| Pass 3 next 1: apply 008 | production | Done by German on Oct 17. Nothing left to do in the client. |
| 008 and the client workarounds | `_flushOnce` parking, `RecallApi.isPermanentReviewRejection`, `_applyReviewClientSide` | **Keep them all.** See "Migration 008" below. |
| Pass 3 next 3: hung flag send, hide-Undo | `_undoHide` | **Gap found and fixed** (below). The hide's Undo waited for the flag send without a limit, then sent the withdrawal without a limit. |
| Hung flag send, sign-out | `_runSignOut` | **Fixed.** Sign-out waited for the flag send without a limit. |
| Hung flag send, automatic sync | `syncPending`, `BrowserForegroundSyncCoordinator._run`, `MainActivity.requestBackgroundSync` | **Fixed.** Both callers run one sync at a time and wait for `syncPending`. A hung flag send therefore stopped the web's 1-minute timer and Android's reconnect callback from retrying *reviews*. |
| Hung flag send, load and rating | `_loadQueue`, `_hideCurrent`, `flag` | Safe. They start the flag flush without waiting for it. |
| Pass 3 next 2: offline after a transport failure | `_flushOnce`, `_rate` | Not changed. This is still next step 1. |
| Withdrawal replay safety | `RecallApi.dismissFlag`, `applyFlag` | `dismissFlag` only updates a row that is still open, so sending it twice is safe. But it cannot stop a hide that arrives *after* it. That shaped the fix (below). |

## The gap: a hung flag send froze hide-Undo, sign-out and sync

"Don't like" and "delete" hide the card and queue a flag. The flag is sent
right away. On a dead connection (a dead zone where the phone still looks
connected, or a dropped pooled socket), that request can stay open for
minutes. On Android that is up to about 15 minutes of TCP retries.

Before this fix:

1. German studies on the train with no real signal. He taps **delete** on
   card 1 by mistake. Card 1's flag send hangs.
2. He taps **Undo**. `_undoHide` sets `undoInFlight` and waits for the flag
   flush to finish. While it waits, every rating tap and every hide is
   ignored. The study screen is frozen until the hung request fails.
3. Even when no flag was being sent, the Undo then called `dismissFlag`
   directly with no limit, so it froze the same way.
4. **Sign out** waited for the flag flush without a limit.
5. Web: the 1-minute timer runs `syncPending` one call at a time and waits
   for it. `syncPending` waited for the hung flag send. Every later tick only
   set a follow-up, so reviews rated meanwhile were not retried when the
   signal came back. Android's validated-network callback has the same
   one-at-a-time guard (`syncInFlight`), with the same effect.

**Fix** (`_flushFlagOutboxBounded`, `_joinFlagFlush`, `_undoHide`):

- `syncPending` and sign-out stop waiting on the flag flush after
  `reviewSendTimeout` (15 seconds). They do not abandon the send itself.
  The flag stays queued until its send settles. Sign-out therefore still
  refuses with `PendingSyncException`, which is its normal offline outcome.
  The next sync tick retries reviews.
- The hide's Undo waits for a running flag flush for at most the same
  bound, then removes the flag entry as before.
- **Ordering:** if a flag pass is still running when the entry is removed,
  that pass may still be carrying this hide. A withdrawal sent directly
  could reach the server first, match no open row, and leave the hide open.
  For a "delete", that would ask the weekly review to remove a card German
  had undone. So in that case the withdrawal is queued in the flag outbox and
  a follow-up pass is scheduled. It goes out only after the running send
  settles.
- When no flag pass is running, the direct withdrawal is also limited to
  the bound. If it fails or times out, it is queued as before. A late copy
  of it is harmless because it is the same conditional update.

Unlike pass 3's review fix, a hung flag *send* is not abandoned and retried.
A review replay is deduplicated on `client_event_id` (the review's event ID)
whenever it arrives. A flag replay is too, but a late hide arriving after its
withdrawal is not. Abandoning the send would make that race possible.

**Tests:** `test/flag_send_hang_test.dart`, using a 50 ms bound:

- *Undo of a hide during a hung flag send returns after the bound, and its
  withdrawal goes out only after that send.* Card 1 is restored and rating
  works at once. No withdrawal is sent while the hide is in flight. When the
  hung send lands, the withdrawal follows it (`appliedWhenDismissed == 1`),
  both outboxes drain, and the card is not hidden on the server.
- *Undo of a hide whose withdrawal hangs restores the card and queues the
  withdrawal.*
- *Sign-out during a hung flag send refuses and keeps the flag.*
- *A hung flag send no longer stalls the web timer's review retry.* This
  drives the real `BrowserForegroundSyncCoordinator`: a queued review is
  delivered once the connection returns, while the flag send still hangs.
- *A flag send that answers within the bound still delivers.* This is the
  control case: a direct withdrawal, nothing left queued, and sign-out
  succeeds.

Before the fix, the first four failed on their 5-second guards (`Undo waited
on a flag send that never returns`, `Undo waited on a withdrawal that never
returns`, `Sign-out waited on a flag send that never returns`, `syncPending
waited on a hung flag send`). The control test passed. As a mutation check,
I removed only the "queue the withdrawal behind a running send" guard. The
ordering test then failed with `Expected: empty, Actual: ['…']`: the
withdrawal had been sent while the hide was still in flight.

## Migration 008: can any client workaround go?

No. Keep all three:

- **Parking a permanently refused review (#140)** must stay, even with 008
  live. A queued review **without a `client_id`** never uses `apply_review`.
  `RecallApi.applyReview` sends it through `_applyReviewClientSide`, which
  inserts into `review_log` directly. For a hard-deleted card, that still
  raises 23503 (a foreign-key error) on today's production server. Parking
  also covers every other class-23 error (check, not-null, unique), which
  008 does not touch.
- **`_applyReviewClientSide` and its `PGRST202`/`42883` fallback** must stay
  for older servers: a restored backup, a fresh project before 006, or a
  rolling deploy. It is also the only path for those legacy reviews.
- **The pass-3 legacy rule** (a review without `client_id` keeps the
  unbounded send) is unchanged for the same reason. Its replay is not
  deduplicated on the server.

008 does make the common case quiet. A review with a `client_id` for a
deleted card now returns 0, is acknowledged and drains. It no longer parks,
shows "1 couldn't sync" or blocks sign-out. The client already accepts any
integer as an acknowledgement (`_requireReviewLogId`), so it needed no
change.

## Top 3 next

1. **Mark the session offline after a transport failure in `_flushOnce`**
   (pass 3 next 2, unchanged). In a silent dead zone, every rating still
   starts a send that waits out the 15-second bound. An Undo made during
   that time waits up to 15 seconds. The first rating's Undo is closed with
   the untrue notice "Synced reviews cannot be undone", and the header says
   "N syncing" instead of "Offline". Fold in pass 2's stale `serverError`
   label and the reworded notice ("Sent reviews cannot be undone"). The cost
   is unchanged: one transient failure holds ratings locally until the next
   resume, reconnect or browser tick.
2. **A hung flag send still holds the flag loop.** New flags and withdrawals
   queue behind it until the OS gives up, which takes up to about 15 minutes
   on Android. Nothing is lost and nothing waits on it any more, but a hide
   made then reaches other devices late. Abandoning the send safely needs a
   server-side ordering guarantee: a withdrawal that records a tombstone, or
   an `apply_flag` RPC that refuses a flag already withdrawn. That is a
   Recall schema change and needs German's approval.
3. **Bound the load's and Keep going's network reads.** If `fetchQueue` or
   `fetchAheadQueue` hangs, a cold start with an empty cache stays on its
   spinner, and so does Keep going. A Supabase-level `requestTimeout` would
   cover them, but it changes every request and its retries, so it needs its
   own pass (pass 3 next 3, second half).

## Verification

- `./tool/flutterw analyze`: `No issues found!`
- `./tool/flutterw test`: `All tests passed!` with 1100 passed and 32
  skipped. Pass 3 recorded 1095 passed and 32 skipped; the five additions
  are the new tests.
- `./tool/flutterw test test/flag_send_hang_test.dart`: before the fix,
  1 passed and 4 failed. After the fix, 5 passed. With the ordering guard
  removed, 4 passed and 1 failed.

These are Flutter controller tests with a fake API whose flag send never
returns. The web test drives the real browser sync coordinator with a fake
platform. They do not exercise a real device on a dead network, Android's
native `MainActivity` guard, or the deployed Supabase project.

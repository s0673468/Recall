# Reliability pass 5 — 2026-10-17

Base: `main` at `895ad31` (#146). Android and web only. No card, deck or
article content changed. The fix is in the shared `ReviewController`, so it
behaves the same on Android and the web.

I started from pass 4's "top 3 next", item 1. It is the most valuable item
for daily use: it affects every study session that hits a dead zone. Items
2 and 3 are either blocked on a Recall schema change or need their own pass.

## What was checked

| Area | Where | Result |
|---|---|---|
| Pass 4 next 1: offline after a send failure | `_flushOnce`, `_rate`, `undo` | **Gap confirmed and fixed** (below). |
| Pass 2's stale "Server error" label | `_flushOnce` reconnect, `keepGoing` catch | **Fixed in the same change.** A reconnect cleared `offline` but left `serverError` set. Keep going's failure never classified its error. |
| Retry triggers once offline | `AppShell.didChangeAppLifecycleState`, `MainActivity` validated-network callback, `BrowserForegroundSyncCoordinator` (1 minute), done screen | All call `syncPending` or `load`, and both clear offline once something is delivered. While offline, the done screen shows **Reload** instead of Keep going. Reload runs `load`, which flushes first. |
| A pass that delivers and then fails | `_flushOnce` | Kept online. A delivery proves the server can be reached (#137, `outbox_batch_attempt_test`). The next pass decides. |
| Local storage errors in a flush | `markReviewAttempted` inside the send loop | Not treated as offline. Only an error from the send itself counts. |
| Permanent refusals (class 23) | `RecallApi.isPermanentReviewRejection` | Unchanged. They are parked and never mark the session offline. |
| Notice wording "Synced reviews cannot be undone" | `_flushOnce`, `_undoCurrentAction`, `UndoConflictException` | Not changed. Six existing tests assert the exact text, and the ticket does not allow editing them. Listed as next step 1. |

## The gap: a silent drop kept every later rating on the network

A connection can die without the phone noticing: a dead zone where Wi-Fi
or mobile data still looks connected. Before this fix, a failed review send
left the session marked as online:

1. German studies on the train and the signal drops silently. He rates
   card 1, and its send fails (or hangs for the 15-second bound from pass 3).
2. The header still says "1 syncing", not "Offline · 1 waiting".
3. He rates card 2. `_rate` sees `offline == false` and starts another send
   into the dead network.
4. He taps **Undo** on card 2 (a mis-tap). Undo waits for that running send,
   up to 15 seconds each time, with rating locked. If the send for card 2
   started first, its Undo is closed with "Synced reviews cannot be undone",
   even though nothing reached the server.
5. Every later rating repeats steps 3 and 4 until the signal comes back.

**Fix** (`_flushOnce`):

- When a pass delivers nothing and its send fails, from the transport, a
  timeout or a retryable server error, the session goes offline. From then
  on, `_rate` keeps ratings local. Their Undo works at once, and the header
  reads "Offline · N waiting to sync".
- `serverError` is set from the same classification that `load` uses
  (`_isServerError`). The header therefore says "Server error" for a 5xx
  answer and "Offline" for a transport failure. A later transport failure
  replaces an older "Server error".
- A delivery clears both `offline` and `serverError`. Before, it cleared
  only `offline`.
- A pass that delivered at least one review and then failed keeps the
  delivery's evidence and stays online. The next pass decides.
- An error from local storage, such as `markReviewAttempted` throwing, is
  not taken as evidence about the network.

**Keep going** now sets `serverError` from its fetch error instead of always
saying "Offline".

**The cost** is the one pass 3 and pass 4 already accepted: after a single
transient failure, ratings stay local until the next app resume, Android
validated-network change, 1-minute web tick, Reload, or deck switch.
Nothing is lost: reviews are in the durable outbox and replay is
deduplicated on `client_event_id`. On Android, if the app stays in the
foreground and the network never changes, reviews wait until the done
screen's Reload or the next resume.

**What it does not fix:** the first rating in a dead zone still starts a
send before anything is known. Its Undo still closes, and ratings made while
that first send hangs still wait up to the 15-second bound.

## Tests

`test/send_failure_offline_test.dart` (8 tests):

- *A failed send marks the session offline and keeps later ratings local
  and undoable.* No new send is started for the second rating. Undo restores
  it without a notice, and the reconnect delivers and clears offline.
- *A hung send marks the session offline after the bound.* Same checks with
  a send that never returns.
- *A server error during a send is labelled, then cleared on reconnect.*
- *A transport failure after a server error is labelled offline, not
  "Server error".*
- *A local outbox failure is not taken as a network failure.*
- *Keep going labels a server error from its fetch* (and then a transport
  failure as plain offline).
- *A drop after a delivery in the same pass waits for the next pass before
  going offline.*
- *A send that succeeds keeps the session online.* This is the control case.

Before the fix, five failed on their `offline` or `serverError` checks
(`Expected: true, Actual: <false>`). The local-storage and success controls
passed. The delivery-then-drop test was added with the narrowed rule.

Mutation checks:

- Counting local errors as send failures (removing `if (sending)`) fails
  *a local outbox failure…*.
- Going offline even after a delivery (removing `&& acknowledged.isEmpty`)
  fails *a drop after a delivery…*. That first, broader version also failed
  two existing tests in `outbox_batch_attempt_test.dart`, which is why the
  rule was narrowed.

## Top 3 next

1. **Make the Undo notice honest.** Change "Synced reviews cannot be
   undone" to "Sent reviews cannot be undone" in `_flushOnce`,
   `_undoCurrentAction` and `UndoConflictException.toString`. The old text is
   still shown when the first send in a dead zone closes an Undo, even though
   nothing was synced. Six existing tests assert the old text
   (`recall_undo_test`, `outbox_batch_attempt_test`, `recall_api_undo_test`,
   `production_scale_acceptance_test`), so the ticket must allow updating
   them.
2. **A hung flag send still holds the flag loop** (pass 4 next 2,
   unchanged). Abandoning it safely needs a server-side ordering guarantee: a
   withdrawal tombstone, or an `apply_flag` RPC that refuses a withdrawn
   flag. That is a Recall schema change and needs German's approval.
3. **Bound the load's and Keep going's network reads** (pass 4 next 3,
   unchanged). If `fetchQueue` or `fetchAheadQueue` hangs, an empty-cache
   cold start and Keep going stay on their spinner. A Supabase-level
   `requestTimeout` changes every request and its retries, so it needs its
   own pass.

## Verification

- `./tool/flutterw analyze`: `No issues found!`
- `./tool/flutterw test`: `All tests passed!` with 1108 passed and 32
  skipped. Pass 4 recorded 1100 passed and 32 skipped; the eight additions
  are the new tests.
- `./tool/flutterw test test/send_failure_offline_test.dart`: before the fix,
  2 passed and 5 failed (7 tests at that point). After the fix, 8 passed.

These are Flutter controller tests with a fake API whose review send fails,
hangs or returns a `PostgrestException`. They do not exercise a real device
on a dead network, Android's native `MainActivity` callback, or the deployed
Supabase project. I did not render the header label on a device; the label's
mapping (`serverError ? 'Server error' : 'Offline'` in `study_screen.dart`) is
unchanged.

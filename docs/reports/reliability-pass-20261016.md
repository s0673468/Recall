# Reliability pass — 2026-10-16

Base: `main` at `c4a42df` (#133). Android and web only. No card, deck or
article content changed. To stay clear of the speed-pass PRs in flight
(#132, #133, #135, #136), this pass did not edit `RecallApi.fetchQueue`,
`ReviewController.load` or `LocalReviewStore`'s read/mark paths.

## What was checked

| Daily scenario | Where | Result |
|---|---|---|
| Rating offline, then reconnecting | `ReviewController._rateVisibleCard`, `_flushOnce`, `syncPending`; app-resume, Android `NetworkCallback` and browser timer/`online` wake paths | **Gap found and fixed** (below) |
| App killed mid-sync | `markReviewAttempted` before transport; `apply_review` RPC keyed on `client_event_id` | Safe. The RPC is idempotent and a killed attempt replays cleanly. Already covered by `local_server_ack_drain_test`, `recall_api_idempotency_test` and the native restart tests. |
| Token refresh during sync | `_onAuthChanged`, `_flushStillOwnsSession` | Only a new user id (or an explicit `signedIn` event) resets the session, so a `tokenRefreshed` event doesn't interrupt a flush. Owner checks stop a flush across an account switch. |
| Switching decks quickly | `load()` `_loadSequence` guards; `selectDeck` | Every write in `load()` is re-checked against its token after each await. A superseded load only runs the deck-independent single-flight flush. No race found. A related catch-up gap is candidate 1 below. |
| Daily limits across midnight/timezone/DST | `local_day.dart`, `backlog_catch_up.dart`, `RecallApi._newCardsIntroducedToday`, `stats_service.dart`, reminders | Local midnight is handled correctly and covered by `rating_midnight_progress_test` and `stats_service_calendar_test`. There is a DST gap in the new-card budget (candidate 3). |
| Error messages shown to the user | `ReviewState.error`, sync badge, sign-out `PendingSyncException` | Load failures show a fixed, plain message, never a raw exception. The sync badge was wrong after reconnecting; this fix corrects it. Two smaller message issues are listed under "Also noted". |

## The gap: a session that went offline stayed offline

`ReviewState.offline` is set when a load fails. Only a later successful
`load()`, `keepGoing()` or catch-up choice cleared it. A successful outbox flush
did not clear it, so the sync badge stayed stale. It also kept later ratings
from syncing, because the rating path deliberately skips the network while
offline:

```dart
// review_controller.dart, end of _rateVisibleCard
if (!_state.offline) unawaited(_flushOutbox());
```

That gate is intentional and stays. A flush marks each review as attempted,
and an attempted review can no longer be undone (#91). Sending reviews into a
dead network would cost every offline rating its Undo.

The problem was that nothing reset the flag mid-session. On resume,
`refreshIfIdle` deliberately does not reload while a card is on screen.
Android's reconnect callback, the browser's minute timer and app resume all call
`syncPending()`, which delivered the queued reviews but left `offline: true`.

Trace of a typical commute:

1. The app opens without signal. It shows the cached queue, and `offline` is
   `true`.
2. German rates 10 cards. They are queued, nothing is sent, and Undo works.
3. Signal returns, and Android's `NetworkCallback` runs `performSync`. Those 10
   are delivered and `pendingSync` drops to 0, but the header still says
   **"Offline"**.
4. He rates 40 more in the foreground. Line 1610 skips every flush, so all 40
   stay on the phone while the header reads "Offline · 40 waiting to sync".
5. Opening Recall on the web meanwhile shows those 40 cards as still due. That
   invites duplicate reviews and leaves scheduling stale until the phone
   happens to resume or reload. On the done screen, "Keep going" is also
   hidden, because it requires `!offline`.

**Fix** (`ReviewController._flushOnce`): when a flush gets at least one
server acknowledgement, the server is evidently reachable again, so the
session clears `offline` along with updating `pendingSync`. A flush that
delivers nothing leaves the flag alone, so ratings made while genuinely offline
keep their Undo.

**Tests**: `test/offline_reconnect_flush_test.dart`.

- *A delivering sync clears offline so later ratings sync again.* The session
  goes offline mid-way, and a rating stays local and undoable. A reconnect
  `syncPending()` delivers it, clears `offline` and keeps the active card. The
  next rating is then delivered behind the UI. Before the fix this test failed
  with `offline` still `true`.
- *A sync that still cannot deliver keeps the session offline.* The flag stays
  set, the next rating makes no network attempt, and its Undo stays available.

## Top 3 next candidates

Ranked by how often German would hit each one and how much it would cost him.

1. **Switching decks resets the global catch-up progress.** Catch-up state is
   one key per owner (`recall_catch_up_v1`), but `_buildCatchUpView`
   (`review_controller.dart:984-1023`) counts only the selected deck's due
   cards. When that deck has none, it saves `none`. When the deck is under the
   offer threshold, it resets `dismissed`. So a quick look at a small or
   new-only deck during an active catch-up drops `completedToday`. Back on all
   decks, the daily cap starts again from 0, or a dismissed offer reappears.
   This only affects presentation, but it would come up often. The fix is to
   persist or clear catch-up state only from the all-decks stream it describes.
2. **One permanently failing review blocks the whole outbox.** `_flushOnce`
   stops at the first error and does not distinguish permanent errors from
   transient ones. `apply_review` inserts the `review_log` row before checking
   that the card exists, and `review_log.card_id` has a foreign key to
   `cards(id)`. A card hard-deleted while its review is queued therefore raises
   `23503` on every retry. The RPC's "card hard-deleted while queued" branch
   can never run, every later review stays queued, and sign-out refuses with
   `PendingSyncException`. The importer currently soft-deletes (`deleted`
   flag), so this needs a hard delete to trigger. Its blast radius is the
   largest of the three. The fix belongs in the RPC: check the card before
   inserting the log row. A narrow client-side park for permanent PostgREST
   codes is the alternative.
3. **The new-card daily limit is not enforced in the last hour of a DST
   fall-back day.** `RecallApi._newCardsIntroducedToday` ends "today" at
   `localStart.add(Duration(days: 1))`, which is 24 real hours after midnight.
   On a 25-hour day (Europe 2026-10-25, US 2026-11-01), reviews from 23:00 to
   23:59 fall outside the `rating_at` window. In that hour every reload counts 0
   introductions and serves another full batch of new cards. The fix is
   `DateTime(y, m, d + 1)`, plus an injectable clock so a test can pin the
   date. `BacklogCatchUp.recentDailyAverage` has the same problem in its
   cutoff (`today.subtract(Duration(days: 13))`), which drops a day for about
   two weeks after the change. This was not fixed here because the new-card
   count is part of the `fetchQueue` path that the in-flight speed PRs touch.

Also noted, lower priority:

- **Retry after an account-setup failure spins forever.** This comes from
  reading the code; no test reproduces it yet. If `beforeSessionLoad` throws,
  the screen says "Recall could not prepare this account. Try again." Its
  Retry button calls `refresh()` → `load()`, which does not re-run account
  setup. With no active owner scope, `_loadHiddenCardsQuietly` returns `null`,
  and `load()` returns while still `loading: true`.
- **Every load failure is called "offline".** `load()` catches all errors the
  same way. A server error (RLS, 5xx, missing RPC) on a working connection is
  shown as "Recall is offline…".

## Verification

- `./tool/flutterw analyze`: `No issues found!`
- `./tool/flutterw test`: `All tests passed!` with 979 passed and 32 skipped.
  The baseline on `c4a42df` was 977 passed and 32 skipped; the two additions
  are the new tests.
- New test before the fix:
  `./tool/flutterw test test/offline_reconnect_flush_test.dart` gave 1 passed
  and 1 failed (`Expected: false, Actual: <true>` on `state.offline`).

These are Flutter unit and controller tests with a fake API. They do not
exercise a real device's connectivity callback or a deployed Supabase project.

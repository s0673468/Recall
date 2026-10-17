# Reliability pass 2 — 2026-10-17

Base: `main` at `d4c9da1` (#140), which includes tonight's #132/#133/#135/#136,
#137, #138, #139/#141, #140, #142 and #143. Android and web only. No card,
deck or article content changed. The fix is in the shared `ReviewController`,
so it behaves the same on Android and the web.

This pass focused on how tonight's fixes interact with each other.

## What was checked

| Interaction | Where | Result |
|---|---|---|
| Parked reviews (#140) + Undo | `_flushOnce`, `_undoCurrentAction`, `_markRemainingAttempted` | Safe. A review is marked attempted, and its Undo closed, before the RPC, so a parked review was already non-undoable. Undo of a later rating removes only its own `client_id`. The parked set is keyed by owner scope. |
| Parked reviews + load / Keep going | `_withoutPendingReviews`, `keepGoing` | Safe. A parked card stays out of every fetched queue. Keep going ignores parked entries when deciding whether it is offline. |
| Parked reviews + reconnect (#137) | `_flushOnce` `reconnected` | Working as designed: a refusal alone does not clear `offline`; only a delivery does. |
| Parked reviews + sign-out | `_runSignOut`, `store.clear(requireEmptyOutboxes: true)` | Working as designed (never drop a review), but sign-out stays blocked until 008 is in production. See next step 1. |
| Server error (#142) + catch-up (#138) | `_chooseCatchUpMode` | **Gap found and fixed** (below). |
| Server error + reconnect / Keep going | `_flushOnce`, `keepGoing` | Small label issue only. See "Also noted". |
| DST (#139/#141) + catch-up | `BacklogCatchUp.dayKey`, `normalizeLocalState`, `recentDailyAverage`, `_restoreCatchUpState` | Safe. Day keys come from wall-clock fields, the recent window uses calendar days (#141), and an Undo across midnight compares day keys instead of durations. |
| Setup Retry (#142) + corrupt outbox (#143) | `_prepareSignedInSession(retry: true)` → `_loadSafely(sessionReady: true)` | Safe. The retried setup's load is also guarded against a corrupt outbox. |

## The gap: choosing a catch-up mode made an offline session look online

`_chooseCatchUpMode` (used by **Start catch-up** and **Show all**) only
re-slices cards already on the device. It makes no network call. But it set
`offline: false`, a line carried over from the load path when catch-up was
first added (#35).

The catch-up offer appears after time away, which is also when the app is
likely to open without signal. Before this fix:

1. Recall opens offline with a large backlog. The cached queue and the
   catch-up offer appear, and the header says **"Offline"**.
2. German taps **Start catch-up**. `offline` becomes `false`, and the header no
   longer says Offline.
3. He rates the first card. The rating path's offline guard
   (`if (!_state.offline) unawaited(_flushOutbox())`) no longer applies.
   The flush marks the review attempted, closes its Undo, and shows
   **"Synced reviews cannot be undone"**. Then it fails on the dead network.
   Nothing was synced, but the Undo is gone for good.
4. From then on, every rating starts a network attempt, and the header reads
   "N syncing" instead of "Offline · N waiting to sync". After a server error,
   the "Server error" label disappears as well.

This is the same failure #137's report warned about ("sending reviews into a
dead network would cost every offline rating its Undo"), reached through
catch-up.

**Fix:** `_chooseCatchUpMode` no longer touches `offline` (or `serverError`).
Offline is cleared only by evidence the server is reachable: a successful
load, a delivering flush (#137) or a successful Keep going. That was already
the rule everywhere else.

**Tests:** `test/catch_up_offline_choice_test.dart`

- *Starting catch-up offline keeps the next rating local.* The session stays
  offline, no send is attempted, no "synced" notice appears, and Undo restores
  the card.
- *Showing all after a server error keeps its label and local ratings.* The
  same checks, plus `serverError` stays set.
- *A reconnect after an offline catch-up choice clears offline.* Once the
  connection returns, `syncPending()` delivers the queue and clears offline
  through the #137 path, and catch-up progress is kept.
- *A catch-up choice online still syncs behind the UI.* This is the control
  case: an online choice keeps delivering ratings.

Before the fix, the first two failed on `state.offline` (`Expected: true,
Actual: <false>`). A throwaway copy with that check removed showed the real
harm: one send attempt into the dead network, and the notice
`'Synced reviews cannot be undone'`.

## Top 3 next

1. **Apply migration 008 in production (needs German's approval: Recall,
   production write).** Until it is applied, a review for a hard-deleted card
   is parked again on every restart. It shows "1 couldn't sync" for good and
   makes sign-out refuse with `PendingSyncException`. Back up `review_log` and
   `cards` first, then apply `008_apply_review_missing_card.sql` and run
   `verify_apply_review.sql` / `verify_schema.sql`.
2. **A silent mid-session network drop costs one Undo and leaves the badge
   saying "syncing".** If the connection dies while `offline` is `false` (no
   load has failed yet), a failed `_flushOnce` never sets `offline`. The
   oldest queued rating loses its Undo with the same misleading "Synced"
   notice, and the header shows "N syncing" until the next load. A possible
   fix: mark the session offline after a transport (non-Postgrest) flush
   failure, and rely on #137's delivery path to clear it. Check first that
   Android's resume and `NetworkCallback` and the browser timer retry often
   enough. Also reword the notice to "Sent reviews cannot be undone".
3. **The server-error label can go stale or go missing.** `keepGoing` sets
   `offline: true` on failure without classifying the error. `_flushOnce`'s
   reconnect clears `offline` but leaves `serverError` set. So a server error
   from Keep going is labelled "Offline", or an old server error labels a
   later transport failure. Today this is mostly hidden, because the done
   screen has no header and Reload reclassifies the error. Fix it by setting
   `serverError: _isServerError(error)` in `keepGoing`'s catch and clearing it
   on reconnect.

## Verification

- `./tool/flutterw analyze`: `No issues found!`
- `./tool/flutterw test`: `All tests passed!` with 1090 passed and 32
  skipped. The baseline on `d4c9da1` was 1086 passed and 32 skipped; the four
  additions are the new tests.
- New test before the fix:
  `./tool/flutterw test test/catch_up_offline_choice_test.dart` gave 1 passed
  and 2 failed. After the fix, 4 passed.

These are Flutter controller tests with a fake API. They do not exercise a
real device's connectivity or a deployed Supabase project.

# Study session UI state hunt — 2026-10-22

Read README first; no repository AGENTS.md exists. Scope: shared Android/web
study UI and controller state. Only invented in-memory fixtures were used. No
card/article content, existing tests, dependencies, remotes or running services
were changed; no backend, user data or credentials were accessed. Sync paging
(#161), reminders (#160), scheduling/import (#159), and session isolation/offline
recovery (#158) were excluded. The runner owns the commit.

## Fixed findings

1. **Undo inflated the global due count.**
   `lib/features/review/application/review_controller.dart:1767`, `:2247`,
   `:2372`, `:2693`: rating/hiding a bonus learning card before its due time did
   not decrement the aggregate, but undo after its due time incremented it.
   Undo also incremented an already-zero aggregate even when the original
   decrement had been clamped to zero. Both Undo records now remember whether
   the action actually reduced the count; refreshing Undo metadata preserves
   that fact. `test/study_session_ui_state_test.dart:19`, `:73` reproduce both
   cases for ratings and hides. All four tests failed on original source
   (expected zero, got one) before the fix. Queue/card restoration and session
   progress are checked too. This reverses a presentation delta; it does not
   change scheduling or establish a new count authority.

2. **Completing a flag save could pop Study instead of its sheet.**
   `lib/features/review/presentation/screens/study_screen.dart:739`: two quick
   reason selections each saved and popped a route; the second completion
   closed the underlying Study route. Cancelling the sheet during its pending
   save caused the same route loss. One pending selection is now accepted per
   sheet, and completion only pops that sheet while its captured route is
   current. `test/study_flag_sheet_submission_test.dart:27` gates the local
   write and exercises both gestures through a real Material navigator. Both
   tests failed before the fix because Study disappeared. They now verify one
   saved flag with the first selected reason, an intact Study route and an
   unchanged current card/session count. A separately opened flag sheet can
   still submit another report; there is no controller-level flag deduplication
   or new input validation.

## Checked and rejected as additional findings

| Area | Evidence and disposition |
| --- | --- |
| Rapid ratings/reveal | `review_controller.dart:1560`, `:1603`: reveal is idempotent; rating requires a revealed card and locks before its first await. `test/recall_review_controller_test.dart:205` covers simultaneous ratings producing one durable event. No additional double-rating bug established. |
| New/learning/review counts | `lib/features/review/application/review_state.dart:67`, `:68`, `lib/features/review/data/models.dart:210`, `study_screen.dart:417`: the remaining suffix supplies counts; state 0 is new and learning/relearning/review are intentionally grouped as due. `test/recall_review_controller_test.dart:362`, `:448`, `:589` cover aggregate versus loaded batch, future bonus cards and stale count responses. The Undo deltas above were the new count defects. |
| Undo identity and errors | `review_controller.dart:2634`: Undo blocks rating, removes its own durable event and restores the previous card front/progress; attempted sends expire Undo. Existing `test/recall_undo_test.dart:57`, `:361`, `:404` cover local undo, the visible card and final-card undo. No additional defect reproduced. |
| Session end/bonus batches | `review_controller.dart:1463`, `study_screen.dart:119`: Keep going is single-flight while loading, retains the session count and excludes pending reviews/hidden cards. `test/recall_review_controller_test.dart:491`, `:533` cover relearning bonus cards and empty-batch exhaustion. No additional finding; storage recovery remains outside this ticket. |
| Background/resume | `lib/navigation/app_shell.dart:94`, `review_controller.dart:1358`: foreground sync refreshes only idle/stale sessions, retaining an active card. `test/recall_review_controller_test.dart:637`, `:666`, `:1052` exercise idle refresh and preserving the card/answer during refresh. No new lifecycle displacement found. |
| Hidden/flagged cards | `review_controller.dart:1021`, `:864`, `:2222`: load filters pending ratings and hidden IDs; retained sessions drop hidden upcoming cards without displacing the card in hand. `test/recall_review_controller_test.dart:846`, `test/recall_flag_test.dart:258`, `:391` cover remote hides, bonus filtering and refresh during hide. Ordinary quality reports intentionally do not hide cards. No new queue leak established. |
| Refused saves/hung sends | `review_controller.dart:1614`, `:2267`, `:2717` release action locks in finally blocks. `test/review_refused_save_test.dart:150`, `test/review_send_timeout_test.dart:32`, `test/flag_send_hang_test.dart:30` cover refusal/retry and bounded waits without inventing another recovery policy. No additional lock bug established. |

## Validation

Used the pinned Flutter 3.47.1 through `tool/flutterw`. Copied the installed
pinned SDK into the ignored repository build directory so its mutable caches
stay local. Dependencies were resolved with `./tool/flutterw pub get`, with no
lockfile change. Commands used this repository-local environment:

```sh
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
export RECALL_FLUTTER_ROOT="$PWD/build/toolchain/flutter-3.47.1"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/build/tool-config"
export XDG_CACHE_HOME="$PWD/build/tool-cache"
export TMPDIR="$PWD/build"
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_session_ui_state_test.dart` before controller fix | Exit 1: all 4 regressions failed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_flag_sheet_submission_test.dart` before sheet fix | Exit 1: both regressions failed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_session_ui_state_test.dart test/recall_undo_test.dart test/recall_flag_test.dart test/recall_review_controller_test.dart` | Exit 0: 91 passed, 1 skipped. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_flag_sheet_submission_test.dart test/recall_flag_test.dart` | Exit 0: 31 passed, 1 skipped. |
| `./tool/flutterw analyze --no-pub` | Exit 0: no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0: 1,244 passed, 2 skipped on final code/tests. |
| `git diff --check` | Exit 0. |

Acceptance is controller and rendered Material widget testing, including actual
tap/navigation behavior; no Android device or live browser/backend run was
performed. Apple mobile tests were excluded.

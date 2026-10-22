# Recall second technical hunt — 2026-10-21

README.md was read first. Scope: shared Android/Dart study-session code and
invented, in-memory fixtures. No study material, real user data, credentials,
Supabase configuration, deployed services or Apple mobile code was accessed or
changed. Existing tests were neither edited nor deleted. Git metadata was only
read; the runner owns committing this work.

The first hunt's settings recovery, retry saves and Stats paging fixes were left
alone. Scheduling/DST, parser caches and large-list performance were not hunted
again. Existing tests for those areas still run in the required full suite.

## Findings fixed

1. **A delayed report/hide could cross an account boundary.**
   The old producer captured its card, awaited an event ID, then appended to
   whichever owner's flag outbox was active. After a committed append, a late
   hide could also advance the replacement owner's matching card, create Undo,
   cache the hide under that owner, and show an old-account notice.
   Reports and hides now capture the authenticated session generation and
   storage namespace before awaiting, check ownership before enqueue and after
   settlement, and settle unknown native commits in their original namespace
   (`lib/features/review/application/review_controller.dart:2159`,
   `lib/features/review/application/review_controller.dart:2217`,
   `lib/features/review/data/local_review_store.dart:732`). Account invalidation
   clears transient hides and notices
   (`lib/features/review/application/review_controller.dart:493`). A committed
   old-owner action remains in that owner's durable outbox.
   `test/study_action_account_race_test.dart:122` uses direct synthetic auth
   events without login values. It covers both actions during ID
   minting, after commit, and after a committed write whose native reply is lost.

2. **An acknowledged ordinary review could return after an offline restart.**
   Rating advanced the in-memory queue, but only successful material-validation
   reviews updated the saved queue. Once delivery removed the outbox entry,
   rebuilding the controller/store offline served the original new/due card
   again with its pre-rating scheduling state. A delayed startup fetch could
   likewise cache an already-delivered card again. That exact fetch now filters
   cards consumed while it was in flight
   (`lib/features/review/application/review_controller.dart:827`). Ordinary ratings now update the
   current stream's disposable snapshot too, and local Undo restores that
   snapshot (`lib/features/review/application/review_controller.dart:1791`,
   `lib/features/review/application/review_controller.dart:1839`,
   `lib/features/review/application/review_controller.dart:2770`). Bonus batches
   keep their existing no-snapshot contract; material-validation Again keeps
   its existing retry behavior. A successful server fetch still replaces the
   snapshot wholesale.
   `test/study_snapshot_restart_test.dart:29` covers every new-card rating;
   `:55` covers a due card and a fully consumed queue; `:87` checks the bonus
   boundary; `:104` covers a retained bonus queue after failed refresh; `:129`
   covers a late startup fetch; `:163` covers Undo followed by reconstruction.

3. **Local sync-read failures escaped background tasks or stuck Keep going.**
   Senders handled transport failures but could fail earlier while reading local
   storage. Fire-and-forget launches had no error handler; Keep going awaited
   its outbox reads outside its recovery block and left `loading` true on
   failure. Background launches now contain those errors and retain the queued
   actions; Keep going includes those reads in its existing recovery block
   (`lib/features/review/application/review_controller.dart:1510`,
   `lib/features/review/application/review_controller.dart:1565`). Awaited
   foreground/sign-out sync retains its failure contract.
   `test/background_outbox_read_failure_test.dart:35` injects storage-read
   failures after rating, reporting, hiding, queue loading and Keep going, then
   verifies retries, retained actions and a settled loading state.

## Checked and rejected as additional defects

| Path | Evidence and disposition |
| --- | --- |
| Queue assembly and pending-review exclusion | `lib/features/review/application/review_controller.dart:705`, `:835`, `:1054`: both snapshot and fetched queues exclude pending reviews and hidden IDs. `:653` supersedes earlier loads; `:864` preserves an interacted-with queue. Existing controller, deck-stream and load-race tests pass. No additional queue replacement bug established. |
| New-card budget when sessions cross midnight | `lib/features/review/application/review_controller.dart:743` flushes before a new queue read; `lib/features/review/data/recall_api.dart:351` subtracts introductions from the configured daily limit. `:560` counts first introductions in the current local day. An open session consumes its loaded batch rather than automatically allocating another batch at midnight; an explicit load uses the new day's budget. No budget code changed; the first hunt's day/DST work was not repeated. |
| Undo versus rating, replay and deck/account changes | `lib/features/review/application/review_controller.dart:1648`, `:2699`; `lib/features/review/data/local_review_store.dart:702`: rating/Undo locks, queue/load ownership and attempted-delivery refusal protect the unsent-only Undo contract. Existing rating/Undo isolation and sign-out tests pass. Snapshot restoration is the new fix above; no remote Undo was introduced. |
| Skip, bury and hide | `lib/features/review/application/review_controller.dart:2123`, `:2206`, `:2337`: this controller exposes reporting and persistent hide/withdrawal, not separate skip/bury operations. Hiding does not grade or increase session review counts. Withdrawal is durable before transport, and waits are bounded so it cannot overtake a running hide. Existing flag, hide-owner, withdrawal and hung-send tests pass; producer account isolation is fixed above. |
| Leaving study and foreground resume | `lib/navigation/app_shell.dart:148`, `:269` retain the same controller in the navigation stack; `:93` resumes through sync and idle-only refresh. `lib/features/review/application/review_controller.dart:1391` protects an active card. `:1636` caps the existing wall-clock elapsed measurement. No additional state-loss defect established in the synthetic lifecycle tests. |
| Process reconstruction with unsent actions | `lib/features/review/data/local_review_store.dart:323`, `:405`; `test/offline_rating_sync_e2e_test.dart:199`: durable append precedes advancement, and restart/reconnect retries the original RPC event after a lost reply. Existing offline/native-ACK and serialization tests pass. Delivered-card snapshot resurrection is fixed above. |
| Duplicate IDs, ACK removal and ordering | `lib/features/review/data/local_review_store.dart:132`, `:423`, `:618`: install/counter/random event IDs survive clock rollback and restart; captured identity plus payload grants ACK deletion authority. `lib/features/review/application/review_controller.dart:2804`, `:2837` serialize oldest-first delivery and request a follow-up pass for concurrent appends. Ambiguous identities stay queued. Existing ID, cross-tab ACK, batch-attempt and serialization tests pass. |
| Lost RPC replies and multi-device replay | `lib/features/review/data/recall_api.dart:775`, `:801`, `:811`: transactional RPC is preferred and requires a log-row acknowledgement; transport errors do not silently downgrade it. `lib/features/review/data/review_replay.dart:164` retains the documented legacy conflict policy. Existing RPC, timeout, multi-device and offline replay tests pass. No schema/deployed work or attempt to redesign the documented fallback was made. |
| Explicit sign-out and replacement sessions | `lib/features/review/application/review_controller.dart:396`, `:429`, `:2992`: sign-out closes ingress, joins admitted producers, refuses pending actions and verifies ownership; senders check the API owner and storage scope. Existing sign-out, same-UID replacement, rating and Undo isolation tests pass. Late flag/hide producers were the missing boundary fixed above. |
| Hung/permanently refused sends | `lib/features/review/application/review_controller.dart:2828`, `:2879`, `:3024`: review attempt markers disable unsafe Undo, event-keyed reviews have bounded waits, permanent refusals stay parked/durable, and flag callers use bounded joins without racing withdrawals. Existing timeout, refused-save, park/restart and flag-hang tests pass. Local-read errors are fixed above. |

## Validation

The pinned Flutter **3.47.1** was installed with `./tool/bootstrap_flutter` inside
this repository. `./tool/flutterw pub get` succeeded without tracked dependency
changes. All commands used repository-contained writable caches:

```bash
export HOME="$PWD/.dart_tool/hunt-home"
export TMPDIR="$PWD/.dart_tool/hunt-tmp"
export PUB_CACHE="$PWD/.pub-cache"
export RECALL_FLUTTER_CACHE_ROOT="$PWD/.dart_tool/hunt-sdk"
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_action_account_race_test.dart test/study_snapshot_restart_test.dart` before production fixes | Exit 1; nine regression failures, including four account-boundary and five snapshot/Undo cases. Two initial fixture setup mistakes were corrected before this reproduction run. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/background_outbox_read_failure_test.dart` before background error containment | Exit 1; all four background-read cases failed on captured unhandled errors. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/background_outbox_read_failure_test.dart` after adding the Keep going regression, before moving its reads into recovery | Exit 1; four passed, Keep going failed because loading remained true. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/background_outbox_read_failure_test.dart` with all fixes | Exit 0; five passed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_snapshot_restart_test.dart` with the two final race controls, before their fixes | Exit 1; seven passed, failed-refresh bonus Undo and late-startup snapshot convergence failed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_snapshot_restart_test.dart test/recall_review_controller_test.dart test/audit_catch_up_choice_session_test.dart test/review_scheduling_mutation_test.dart` after those fixes | Exit 0; 62 passed. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only` on final source | Exit 0; **1,251 passed, 32 skipped** under the repository's existing Apple-test exclusion configuration. |
| `git diff --check` | Exit 0. |

An intermediate affected run exposed four unhandled late local-read errors in
existing refused-save tests. These motivated the separate fault-injection
regressions above; the subsequent focused run passed all 37 tests. The final three new test files contain 20 regression/control cases. A full run
before the final Keep going case passed 1,248 tests with 32 skipped; the next passed 1,249 with 32 skipped before the two final snapshot controls were added. One final
full-command launch encountered Flutter's SDK metadata/startup contention while
analyze ran concurrently; it exited before running tests and was retried after
analyze completed.

Verification uses shared Dart/controller tests, synthetic widget fixtures,
in-memory preferences and invented transports. It does not prove Android process
kill/radio acceptance or deployed PostgreSQL behavior. Snapshot writes retain
the existing best-effort cache semantics; the durable outbox remains the write
buffer and the server remains authoritative.

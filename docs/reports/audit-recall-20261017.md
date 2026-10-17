# Recall reliability audit — 2026-10-17

## Review follow-up on `4c6ef88`

Verified the reviewer's P2 at
`lib/features/review/data/local_review_store.dart:799` on that head. A refused
withdrawal leaves the original hide on disk and its replacement in the eager
SharedPreferences cache. `_removeAcknowledged` then sees conflicting payloads
under the hide's ID and cannot drain the successful delivery. Retrying Undo
before releasing the hide send, as the original regression does, conceals it.

Added `test/refused_flag_withdrawal_drain_test.dart` before changing production
code. Its first run exited 1: three tests passed and two failed. The controller
regression found the delivered hide still queued; the storage regression found
three entries remaining instead of one. The controller test never retries Undo:
it releases the send, checks native truth through a fresh store, syncs again to
check for repeat delivery, and verifies sign-out completes.

The fix at `lib/features/review/data/local_review_store.dart:813` records only
the exact withdrawal payload after a definite refusal. The acknowledgement
merge at `:449` excludes that cache-only payload before checking identity
ambiguity. It preserves the original hide's deletion authority and unrelated
producer cache entries without reloading the shared cache. If native truth shows
that another store later committed the withdrawal, normal acknowledgement
protection applies. Unknown write outcomes remain protected. Refusal records
for the same payload are invalidated before a retry, so an earlier refusal
cannot suppress a later unknown write outcome. Records are also cleared after
a successful replacement, acknowledgement write, or clear.

Eight new tests cover:

1. Refused Undo followed by successful hide delivery, repeated sync and sign-out,
   without retrying Undo.
2. Preservation of an unrelated producer's same-key cache entry.
3. A definite thrown refusal whose best-effort cache reload also fails.
4. A refused acknowledgement write followed by a successful retry.
5. A committed withdrawal retried through the original store.
6. A committed withdrawal written through another store.
7. An unknown withdrawal commit retaining its conflicting cache protection.
8. A definite refusal followed by an unknown retry of the same withdrawal.

The eighth regression initially failed against the first fix (seven passed,
one failed); invalidating the earlier refusal before the retry corrected it.

All fixtures are synthetic. Existing tests and card/article content are unchanged.
This follow-up changes only the store, the new test file and this report. Git's
metadata is read-only; the runner owns the commit. Suggested message:
`Fix flag drain after a refused hide withdrawal`.

### Follow-up verification

Used the existing repository-local Flutter 3.47.1 / Dart 3.13.1 runtime and the
environment documented in the original verification section below, including
the writable repository-local `TMPDIR`. No SDK or tooling source changed.

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test test/refused_flag_withdrawal_drain_test.dart --reporter expanded` | Before fix: exit 1, three passed and two failed. Final fix with all guards added: exit 0, eight passed. |
| `./tool/flutterw test test/refused_flag_withdrawal_drain_test.dart test/audit_hide_undo_recovery_test.dart test/acknowledged_cached_flags_test.dart test/local_review_quota_ack_merge_test.dart test/local_server_ack_drain_test.dart test/cross_tab_server_ack_drain_test.dart test/flag_send_hang_test.dart test/signout_isolation_test.dart --reporter expanded` | Exit 0, 75 passed (with the initial five new tests). |
| `./tool/flutterw analyze` | Exit 0, `No issues found!` |
| `./tool/flutterw test --exclude-tags apple-mobile --concurrency=2 --reporter expanded` | Exit 0, 1,129 passed, two skipped. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0, 145 run, one skipped. |
| `git diff --check` | Exit 0. |

An initial full-test launch exited 1 before executing tests because Flutter
version metadata could not be read. It was started alongside the analyzer;
the subsequent full-test run was started after analysis completed.

## Original audit

Audited `main` at `16a81ab` using `git log --since=2026-10-15` and the
changes from `1b9142e^` through that head. This includes reliability passes
2–5, #144–#147, the earlier owner/storage/catch-up fixes, and migration 008's
helpers. Three defects were reproduced and fixed. Two production files changed;
all new fixtures are invented and use in-memory preferences and fake APIs.
Existing tests, card/article content, and existing content fixtures were not
edited. No production services, Git remotes, pushes, PRs, or commits were used.
The runner owns the final commit.
The `.gitignore` exception for `/docs/reports/` makes the requested new report
visible to the runner; the existing `reports/` rule otherwise hides it.

## Findings and minimal fixes

### 1. Hide-Undo could lose its durable operation

Original location: `lib/features/review/application/review_controller.dart:2269`
and `:2291` on the audited head. Fixed at that file's `:2287` and
`lib/features/review/data/local_review_store.dart:790` in this working tree.

Undo removed the queued hide, then tried the server or appended its withdrawal.
If the withdrawal write was refused, the hide had already disappeared from
disk. A process exit between those operations had the same gap. A delete flag
already in transport could still arrive with no durable withdrawal to replay.
The UI could also keep treating the card as hidden while restart had no record
of its pending operation.

The regression holds a hide send open, refuses the withdrawal write, and
reads native truth through a fresh store. Before the fix it expected the
original hide but found an empty outbox. The test then retries, releases the
send, and checks that the withdrawal drains afterward.

Withdrawals now atomically replace their queued hide through `enqueueFlag`
before network delivery. A refused replacement leaves the hide on disk;
a committed replacement leaves the withdrawal. A successful direct withdrawal
removes only its exact acknowledged payload. Failure to persist that local
acknowledgement leaves a replayable withdrawal and still restores the card.
The running-hide ordering rule from #146 is preserved.

### 2. A late hide withdrawal could write into a different account

Original location: `lib/features/review/application/review_controller.dart:2291`
and `:2303`. Fixed at that file's `:2271` and `:2322`, plus
`lib/features/review/data/local_review_store.dart:875`.

While a direct withdrawal waited, the account could change. On failure, Undo
appended the old account's withdrawal into the newly active account's outbox.
On success or failure it removed the card from the new account's hidden cache
and in-memory exclusions before checking whether its Undo was still current.

Two regressions switch from invented owner A to owner B during the request,
with B independently hiding the same numeric card ID. Before the fix:

- Success changed B's persisted hidden set from `{1}` to `{}`.
- Failure put A's withdrawal in B's outbox.

Undo now captures the owner and auth-session generation. Its durable operation
is recorded before sending; acknowledgement and hidden-cache writes use the
captured namespace. A late completion cannot change another session's
presentation or send a new request through that session. Tests also inspect
the next queue request's exclusions and A's retained withdrawal on failure.

### 3. A delayed catch-up choice could cross a deck/account switch

Original location: `lib/features/review/application/review_controller.dart:1383`.
Fixed at that file's `:1389`.

`Start catch-up` / `Show all` awaited storage without binding the operation
to the load or account that offered it. A delayed read could save A's choice
under B, or apply the previous deck's choice to a newly selected deck. A
delayed write could likewise overwrite the newer presentation and clear its
Undo.

Four regressions pause the choice at its read or write, then switch either
the deck or owner. All four fail against the original method: persisted
catch-up state changes after the switch. They now pass. The fix captures the
load, owner, and auth generation; checks them after each await; scopes the
write; and checks cancellation again inside the store lock. Offline status
and the server-error classification from #144 remain unchanged.

## Paths and failure cases checked

| Paths | Trace and evidence |
| --- | --- |
| `lib/features/review/application/review_controller.dart`: auth setup, `load`, `_loadSafely`, Retry/refresh/deck selection | Failed account setup retries its preparation; corrupt outboxes retain recovery data; superseded loads do not publish their old queue. Existing `review_load_errors_test`, `retry_corrupt_outbox_test`, `select_deck_corrupt_outbox_test`, and `review_load_round_trips_test` cover failure, retry and overlapping reads. |
| Same controller: `_rateVisibleCard`, `_undoCurrentAction`, `_flushOnce`, `_markRemainingAttempted`, `_runSignOut`, `keepGoing` | Followed attempted-before-send persistence, timeout with a late response, offline-to-online delivery, second runs, permanent-refusal parking, partial delivery, and account replacement. Existing timeout, offline reconnect/send failure, batch-attempt, parked-outbox, Undo-isolation and sign-out-isolation suites pass. Legacy entries keep their original identity and conservative wait policy. |
| Same controller: `_hideCurrent`, `_undoHide`, `_flushFlagsOnce`, hidden-card refresh | Found findings 1–2. Checked captured-payload acknowledgement when a withdrawal replaces a hide already in transport, late responses, refused storage, a fresh-store restart, and another owner hiding the same ID. Existing flag-hang and hidden-owner suites pass alongside the new regressions. |
| `lib/features/review/data/local_review_store.dart`, `local_review_preferences.dart`, `local_review_write_failure_stub.dart`, `local_review_write_failure_web.dart` | Traced native truth versus eager cache, false writes versus unknown commits, owner migration retry/claim races, keyed reads, captured ACK removal, and duplicate/ambiguous identities. Native retry, quota ACK merge, keyed-read, owner migration, local/server ACK and cross-tab suites pass. Withdrawal replacement is the only new storage behavior. |
| `lib/features/review/application/backlog_catch_up.dart`, `data/catch_up_state.dart`, controller catch-up progress/restore/choice | Found finding 3. Followed deck-stream episode ownership, failed optional progress reads after durable ratings, overlapping loads, Undo, stale cached progress, midnight and DST normalization. Existing committed-progress, deck-switch, persisted-read, backlog and midnight-progress suites pass. |
| `lib/features/review/data/recall_api.dart`: due/history fan-out, daily introductions, `applyReview`, permanent rejection and flag withdrawal | Due paging and introduction history overlap while failures still reject the queue read; new-card bounds use consecutive local midnights. RPC replay accepts the missing-card sentinel and retains retryable failures; the legacy fallback remains distinct. Queue round-trip, introduction DST, idempotency, legacy-delivery, and multi-device tests pass, including restart with a rolled-back clock. Client timestamps still determine newest-review-wins ordering. |
| `lib/features/review/application/review_state.dart`, `presentation/screens/study_screen.dart`, `presentation/screens/decks_screen.dart` | Checked preservation of offline/server-error state, refused-save gesture handling, sync-error counts, lazy rows, search, optional-deck expansion, and count failure/retry. Existing controller/widget suites pass; no presentation source changed. |
| `scripts/supabase/migrations/008_apply_review_missing_card.sql`, `verify/verify_apply_review.sql`, `verify/verify_schema.sql`, `tests/test_apply_review_pg.py` | Read the card-lock-before-log ordering, transactional replay, RLS/invoker behavior, specific-card-FK exception filter, missing-card sentinel, rerun safety and rollback-only verification. No additional SQL defect established by inspection. Actual PostgreSQL execution was unavailable locally; see verification limits below. |
| `lib/navigation/app_shell.dart`, `lib/core/background/browser_foreground_sync_coordinator.dart`, Android `MainActivity.kt` reconnect callback | Traced resume, validated-network wake and web timer into `syncPending`; bounded flag joins release their single-flight callers while review retries remain independent. Browser flag-hang tests exercise the real coordinator. Native device callbacks were inspected, not executed. |
| #148's `.github/workflows/ci.yml`, `tool/flutter_test_shards.py`, `test/support/instant_retry_backoff.dart`, timing fixtures/tool helpers changed since Oct 15 | Read file-shard completeness and failure propagation, retry-timer interception and synthetic frame/checkpoint wiring. Tooling and Flutter contract suites pass. No CI or measurement behavior changed in this audit. |

## New tests

`test/audit_hide_undo_recovery_test.dart` — five tests:

1. Refused withdrawal preserves the original queued hide across a fresh-store
   restart; retry then drains in hide-before-withdrawal order.
2. A fresh process can replay a withdrawal while the old direct request waits.
3. Refusing the local ACK after successful withdrawal leaves Undo usable and
   the withdrawal safely replayable.
4. A late successful withdrawal preserves the other owner's hidden state.
5. A late failed withdrawal preserves the other owner's outbox and exclusions,
   and keeps the withdrawal under the original owner.

`test/audit_catch_up_choice_session_test.dart` — four tests: read/write pause
crossed with deck/owner replacement. Each checks persisted progress in both
relevant namespaces and the identity of the newer queue/view.

Before fixes, the initial three hide tests failed (exit 1). The four catch-up
tests also failed (exit 1) when rerun against the original `_chooseCatchUpMode`
with the rest of the working tree preserved. The focused final command ran
117 tests successfully, including all nine additions and the existing flag,
sign-out, hidden-owner, catch-up and Undo-isolation suites.

## Verification

Host: ger-z Ubuntu WSL (`gema`), pinned Flutter 3.47.1 / Dart 3.13.1. The
installed SDK is read-only in this sandbox, so the SDK and package cache were
copied into ignored repository-local directories. Dependencies were resolved
with `./tool/flutterw pub get --offline --enforce-lockfile`; the checked-in
lockfile is unchanged.

Commands use this repository-local environment (no credentials):

```sh
export RECALL_FLUTTER_ROOT="$PWD/.dart_tool/audit-runtime/flutter"
export DART="$RECALL_FLUTTER_ROOT/bin/dart"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/.dart_tool/audit-runtime/config"
export TMPDIR="$PWD/.dart_tool/audit-runtime/tmp"
export PYTHONDONTWRITEBYTECODE=1 CI=true
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw analyze` | Exit 0; `No issues found!` |
| `./tool/flutterw test --exclude-tags apple-mobile --concurrency=2 --reporter expanded` | Exit 0; `All tests passed!` — 1,121 passed, two skipped. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0; 145 tests run, one skipped. Includes 34,623 synthetic VM/JS scheduler vectors. |
| `python3 -m unittest discover -s scripts/supabase/tests -p 'test_*.py'` | Exit 0, but class skipped: PostgreSQL binaries unavailable; zero SQL tests executed. This is not database verification. |
| `git diff --check` | Exit 0. |

The first tooling run selected a read-only Dart SDK from PATH; setting `DART`
to the pinned local copy fixed the environment. The first full Flutter run
had one failure because optional Python SQL-test discovery generated a binary
`__pycache__` file under the schema-source directory. That contract reads every
file as UTF-8. The generated bytecode was moved into ignored audit output and
bytecode generation disabled before rerunning. No test was edited or skipped
to address either setup issue.

STATUS "Ready for German": the tool safety check rejected
`rm -f scripts/supabase/tests/__pycache__/test_apply_review_pg.cpython-312.pyc`
because `rm -f` style commands are not permitted. That deletion was not retried;
the generated file was preserved with `mv` instead. No approval is needed to
complete this audit.

## Limits carried forward

No real device, live account, production database or browser storage backend
was used. Shared controller/storage behavior was verified with synthetic
fixtures. The full Flutter command excludes retired Apple-mobile coverage.

The previously documented unbounded queue/ahead reads and legacy review sends
remain unchanged. A permanently hung flag send still serializes later flags.
The client also cannot guarantee hide/withdrawal ordering across process death
or independent sessions if an earlier hide is still executing remotely;
that requires the server ordering/tombstone contract already identified in
reliability passes 4–5. The new restart test covers a withdrawal after its hide
has settled, not that server-ordering case. Migration deployment, RLS under a
live database, device networking, and acoustic/resource behavior are not
claimed as verified.

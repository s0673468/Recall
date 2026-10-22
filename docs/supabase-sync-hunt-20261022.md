# Recall app / Supabase sync hunt — 2026-10-22

Read README first; this checkout has no AGENTS.md. Scope: shared Android/web
sync code, invented rows, mocked HTTP and in-memory preferences. Skipped prefs
paging (#157), study-session isolation/offline recovery (#158), scheduling/import
(#159) and reminders (#160). No existing tests or card/article content changed.
No live service, user data, credentials, deployment or Git mutation was used.

## Fixed findings

1. **Remote hidden-card state was truncated at Supabase's row cap.**
   `lib/features/review/data/recall_api.dart:1025` fetched open dislike/delete
   flags with one unpaged select. The controller treated that incomplete set as
   authoritative (`lib/features/review/application/review_controller.dart:2473`),
   so previously hidden cards could reappear on another device or after refresh.
   It now reads ascending flag-ID keyset pages until an empty page. A later-page
   failure rejects the complete read, preserving the controller's existing
   cached-hide fallback. Five new tests in
   `test/recall_hidden_sync_paging_test.dart:50` cover small server caps,
   duplicate card references, cursor order, partial failure, nonadvancing pages,
   and actual controller queue/cache exclusions. The initial three API tests
   all failed before the fix; two controller tests were added afterward.

2. **An empty shared outbox left another instance's pending badge stale.**
   `lib/features/review/application/review_controller.dart:2774` returned early
   after clearing only the parked-error count. If a peer delivered and drained
   the outbox, the next sync still advertised the old number of pending reviews.
   The same-owner empty path now clears both counts. It preserves connection
   status, sends nothing and avoids notifying again when counts already match.
   Both tests in `test/empty_outbox_sync_status_test.dart:33` failed first with
   pending count 1 instead of 0. They cover an earlier transient failure and an
   earlier parked refusal followed by peer acceptance.

The only new rejection is a hidden-state page whose final flag ID fails to
advance. Accepting it could loop forever or publish incomplete exclusions; the
existing fallback keeps known hides instead. Normal empty/short pages, smaller
server caps, sparse IDs, duplicate flags for one card and card IDs in any order
remain accepted. No review payload or timestamp rejection was added.

## Checked and rejected as additional changes

| Area and source | Evidence / disposition |
| --- | --- |
| Review upload, retries, ordering and partial batches: `lib/features/review/application/review_controller.dart:2735`, `:2797`, `:2828`, `:2840`; `lib/features/review/data/local_review_store.dart:355`, `:423` | Single-flight oldest-first sends persist attempts first, drain exact acknowledged identities/payloads, retain the failed suffix and park permanent refusals without dropping them. Existing batch-attempt, send-timeout, park, local/server ACK and cross-tab ACK tests pass. No new delivery defect reproduced. |
| Idempotency: `lib/features/review/data/recall_api.dart:775`, `:799`, `:849`; `scripts/supabase/migrations/008_apply_review_missing_card.sql:110`, `:123` | RPC transaction/ledger is preferred; transport errors do not downgrade, invalid acknowledgements remain pending. Existing API idempotency/null/legacy-ACK tests pass. The documented weaker legacy fallback is unchanged; client code cannot make its separate writes atomic. SQL was inspected, not executed. |
| Conflicting reviews and clock skew: `lib/features/review/data/review_replay.dart:144`, `:164`, `:191`; `lib/features/review/data/local_review_store.dart:132` | Multi-device tests cover both arrival orders, accumulated counters, contention and restart after clock rollback. Event IDs do not depend only on time. Scheduling still uses device review timestamps: a fast device can win against a chronologically later action. This is an existing ordering limitation, not repaired by inventing a time cutoff or rejecting valid offline reviews. |
| Deleted/suspended cards and stale remote reads: `lib/features/review/data/recall_api.dart:308`, `:676`; `scripts/supabase/migrations/008_apply_review_missing_card.sql:103`; `lib/features/review/application/review_controller.dart:807`, `:2429` | Queue reads exclude deleted/suspended cards; missing-card RPC sentinel and pre-migration refusal parking are covered. Pending reviews remain excluded from fetched queues. Hide download exposed finding 1; existing hide-owner/flag tests cover local operations overlaying server reads. |
| Sign-out/account switches: `lib/features/review/application/review_controller.dart:227`, `:429`, `:2925`; `lib/features/review/data/local_review_store.dart:187` | Sign-out waits for admitted producers and refuses to clear pending writes. Upload completions and local ACKs retain captured owner namespaces. Existing sign-out and hidden-owner tests pass, including replacement accounts and delayed completion. No additional change. |
| What users see while behind: `lib/features/review/presentation/screens/study_screen.dart:345`, `:455`; `lib/features/review/application/review_controller.dart:2862` | Pending/error counts drive separate syncing/refusal text; offline/server-error state has its own label. Existing park/widget coverage passes. Found and fixed the stale empty-outbox count in finding 2. Empty storage alone does not prove connectivity. |

## Verification

Pinned Flutter 3.47.1 was bootstrapped into ignored repository-local storage
because the preinstalled SDK cache was read-only. Dependencies were installed
with `./tool/flutterw pub get --enforce-lockfile`; the lockfile is unchanged.
All runtime/cache/temp output stays inside this checkout. Commands use:

```sh
export RECALL_FLUTTER_CACHE_ROOT="$PWD/.dart_tool/sync-hunt/sdk"
export XDG_CONFIG_HOME="$PWD/.dart_tool/sync-hunt/config"
export TMPDIR="$PWD/.dart_tool/sync-hunt/tmp"
export PUB_CACHE="$PWD/.pub-cache"
export DART="$RECALL_FLUTTER_CACHE_ROOT/flutter-3.47.1/bin/dart"
export PYTHONDONTWRITEBYTECODE=1 CI=true
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only test/recall_hidden_sync_paging_test.dart` before the fix | Exit 1; all three initial regression tests failed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/empty_outbox_sync_status_test.dart` before the fix | Exit 1; both regression tests failed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/empty_outbox_sync_status_test.dart test/recall_hidden_sync_paging_test.dart test/cross_tab_server_ack_drain_test.dart test/signout_isolation_test.dart test/review_outbox_park_test.dart` | Exit 0; 53 passed. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0; 1,245 passed, two skipped. |
| `git diff --check` | Exit 0. |

Acceptance is synthetic API/controller tests, not deployed PostgreSQL, device
network transitions or browser storage acceptance. Cross-device clock ordering
and the documented legacy fallback limitations remain. No services were started.
Git metadata is read-only; the runner owns the commit.

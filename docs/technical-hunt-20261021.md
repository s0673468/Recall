# Recall technical hunt — 2026-10-21

Scope: Android/shared Dart code, invented settings and in-memory transports.
No real user data, card/deck/article edits, credentials, backend settings,
deployed services, or Apple mobile work. No repository `AGENTS.md` exists in
this checkout; the supplied task instructions apply. README was read first
and already identifies Android and web as the supported platforms
(`README.md:193`, `README.md:229`), so it was left unchanged.

## Fixed findings

1. **Malformed pending preferences could overwrite cloud settings with defaults.**
   `RecallPrefsController._decode` accepted any syntactically valid JSON through
   the tolerant domain parser. `null`, arrays, numbers, booleans and strings
   became default preferences, taking priority over a valid local mirror and
   being replayed as a user update. The persistence boundary now requires a JSON
   object (`lib/features/settings/application/recall_prefs_controller.dart:262`).
   Existing corrupt-record recovery preserves the original pending payload and
   reloads cloud settings. Invalid disposable mirrors are ignored too.
   Tests: `test/recall_prefs_recovery_test.dart:58` and
   `test/recall_prefs_recovery_test.dart:88`.

2. **Retrying the same setting after a local save failure could skip persistence.**
   The optimistic in-memory value satisfied the unchanged-value shortcut even
   though storage had failed. A retry could fetch the old cloud value, or drain
   an optimistic pending cache entry without repairing the durable local mirror.
   A durable version now distinguishes acknowledged storage from optimistic UI
   state. Only the matching account/version can mark its writes complete
   (`lib/features/settings/application/recall_prefs_controller.dart:237`,
   `lib/features/settings/application/recall_prefs_controller.dart:255`).
   Tests cover an unavailable storage loader, native refusal of either the pending
   record or mirror, and reconstruction after dropping the preference cache
   (`test/recall_prefs_recovery_test.dart:106`,
   `test/recall_prefs_recovery_test.dart:155`). An already durable identical update
   still avoids a second cloud write (`test/recall_prefs_recovery_test.dart:140`).

The new regression file was run against the original tracked controller:
**9 failures, 1 passing control, exit 1**. The fixed controller passes it.
Existing tests were neither edited nor deleted.

## Checked and rejected as new defects

| Path checked | Evidence and disposition |
| --- | --- |
| FSRS button previews, learning graduation, UTC scheduling | `lib/features/review/application/fsrs_engine.dart:68`, `:139`, `:186`: fuzz is disabled, learning steps are reconstructed, previews and ratings use explicit UTC instants. Existing `review_scheduling_mutation_test.dart`, `review_date_boundaries_test.dart` and `recall_fsrs_test.dart` exercise these paths. No new defect established. |
| Cross-device review ordering and retries | `lib/features/review/data/review_replay.dart:164`, `:191`; `lib/features/review/data/recall_api.dart:777`: newest scheduling wins, fallback counters merge under compare-and-swap, RPC is preferred. Existing multi-device/idempotency tests cover the client contract. The documented non-atomic legacy fallback requires a server contract to improve; no schema or deployed changes attempted. |
| Offline durability and lost acknowledgements | `lib/features/review/data/local_review_store.dart:322`, `:421`, `:1205`: serialized appends, identity/payload-based ACK removal, corrupt outbox fails closed. Existing native refusal, unknown commit, quota, ACK race and offline end-to-end tests pass. No change warranted. |
| Hung sends and permanent rejection | `lib/features/review/application/review_controller.dart:2735`, `:2826`, `:2837`, `:2955`: single-flight draining, bounded review/flag waits and per-review parking. Existing timeout, refused-save and park/restart tests pass. Legacy reviews retain their documented unbounded wait because abandoning a non-idempotent send is unsafe. |
| Startup critical path and queue reads | `lib/app/recall_dependencies.dart:74`; `lib/features/review/application/review_controller.dart:672`, `:735`, `:746`: local settings and cached queue precede cloud refresh; independent fetches overlap. `review_load_round_trips_test.dart` and `recall_flow_performance_test.dart` pass. No measured regression demonstrated. |
| Large due backlogs and daily new-card quota | `lib/features/review/data/recall_api.dart:523`, `:560`, `:623`: due/history keysets handle short server pages, stable ties and day boundaries. Existing pagination, introduction and DST tests pass. No scheduling change needed. |
| Large lists and rebuild cost | `lib/features/review/presentation/screens/decks_screen.dart:257`; `lib/features/review/presentation/screens/primer_library_screen.dart:202`: lazy lists. Existing 500-row list tests and `performance_boundaries_test.dart:126` verify bounded mounting and reused card faces during metadata ticks. No new bottleneck established. |
| Memory retention and stale parsing | `lib/features/review/domain/inline_html.dart:555`; `lib/features/review/domain/cloze.dart:201`: both parser LRUs cap at 50 and compare the source before reuse. `lib/features/review/data/recall_read_cache.dart:25`, `:68`, `:71`: API cache uses an Expando, review invalidation and account clearing. Existing cache/parser tests pass. This is structural review, not a native heap profile. |
| Crashes and swallowed errors | `lib/features/review/application/review_controller.dart:150`, `:899`, `:1054`: auth stream errors are handled, server/connection failures have distinct states, optional activity failures degrade without blocking study. Existing load-error, diagnostic, refused-save and corrupt-outbox tests pass. No new crash reproduced. |
| Synthetic scale acceptance | `test/production_scale_acceptance_test.dart:24`, `:166`, `:196`: existing generated fixtures cover 1,600 cards, 32 decks and 12,000 reviews, offline reconstruction and app navigation. Passed in the full suite; no real collection accessed. |

## Fixed by HQ: smaller server caps truncated Stats

`fetchReviewLog`, `fetchNoteTags` and `fetchDueDates` stopped on a page shorter than
500, so a smaller server cap looked like exhaustion and Stats silently lost rows.
They now stop only on an empty page and refuse a cursor that does not advance,
as the due-card loader already did (`lib/features/review/data/recall_api.dart`).
The existing pagination fixture now ends with an empty page, and a new test pages
600 rows through a 250-row server cap
(`test/recall_api_stats_pagination_test.dart`).

## Validation

Flutter **3.47.1** (the repository pin) was bootstrapped inside the ignored
`.dart_tool/hunt-sdk/` directory because the preinstalled SDK was 3.44.2 and its
cache was read-only. Dependency resolution used the existing lockfile without
dependency changes. Tool home, temporary files and package cache were also
kept inside the repository. Commands used these environment variables:

```bash
export HOME="$PWD/.dart_tool/hunt-home"
export TMPDIR="$PWD/.dart_tool/hunt-tmp"
export PUB_CACHE="$PWD/.pub-cache"
export RECALL_FLUTTER_CACHE_ROOT="$PWD/.dart_tool/hunt-sdk"
export PATH="$PWD/.dart_tool/hunt-sdk/flutter-3.47.1/bin:$PATH"
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only test/recall_prefs_recovery_test.dart` against the original tracked controller | Exit 1; 9 regression failures and 1 passing control. Fixed source restored immediately afterward. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/recall_prefs_recovery_test.dart test/recall_prefs_owner_test.dart test/recall_prefs_controller_test.dart` | Exit 0; 30 passed before adding the final mirror-shape case, which is included in the final full run. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `flutter test --no-pub --reporter=failures-only` | Exit 0; **1,230 passed, 32 skipped** under the repository's existing test configuration. |
| `git diff --check` | Exit 0; no whitespace errors. |

Device startup time, Android heap growth, real offline radio transitions,
PostgreSQL execution and deployed acceptance were not measured. The verification
surface is repository Flutter tests, synthetic widget/transport fixtures and
static analysis. No performance claim is inferred from a green test run.

# Preserved lane branches triage — 2026-10-16

33 remote branches. Listed with `git branch -r | grep preserve/`.
Each lane was squash-merged, so commit ids do not match.
Each verdict compares the CHANGE itself against `origin/main`:
test-file identity, line counts, and the matching squash commit on main.

Method note: this clone had no local preserve refs, so the 33 refs
were fetched read-only (`git fetch origin <ref>:<ref>`, no push,
no remote changes) before comparing.

## Verdicts

### preserve/codex/recall-accessibility-20261011 — ALREADY ON MAIN
Restores rating and retention control accessibility on Android. On main via `f9072f2` (#99). All 6 files identical.

### preserve/codex/recall-accessibility-delivery-20261012 — ALREADY ON MAIN
Same accessibility change, rebased through delivery. Same main commit as above. All 6 files identical.

### preserve/codex/recall-ack-drain-20261015 — ALREADY ON MAIN
Drains server acknowledgements against fresh native state with legacy-row queues. On main via #121/#122. Six of seven tests identical; the seventh (unidentified and duplicate transport events) now lives in `test/server_ack_transport_admission_test.dart` on main.

### preserve/codex/recall-action-isolation-20261011 — ALREADY ON MAIN
Isolates rating writes and queue effects by session. `test/rating_session_isolation_test.dart` is on main with 7 added lines. Library diff is later refactoring.

### preserve/codex/recall-catchup-persisted-read-20261015 — PARTLY
Two fixes. The persisted-read fix is on main via `1dc9ea4` (#120); `test/catch_up_persisted_read_test.dart` matches exactly. Missing is the committed-rating independence fix. Missing paths:
- `test/catch_up_committed_rating_progress_test.dart` (307 lines, absent on main)
- the matching hunk in `lib/features/review/application/review_controller.dart` (no `committed_rating` symbols exist in main `lib/`)

### preserve/codex/recall-catchup-split-20261013 — ALREADY ON MAIN
Keeps committed ratings consumed across reloads and preserves catch-up progress across refresh and midnight. On main via `f7ee03e` (#103) and `f297a50` (#104). All 3 test files identical.

### preserve/codex/recall-hidden-delivery-20261012 — ALREADY ON MAIN
Combines hidden-owner fences with sign-out isolation. `test/hidden_owner_isolation_test.dart` identical on main; sign-out suite on main is a superset.

### preserve/codex/recall-hidden-isolation-20261011 — ALREADY ON MAIN
Keeps hidden-card refreshes in their original account plus session isolation. Main versions of both test files are supersets.

### preserve/codex/recall-hidden-owner-20261015 — ALREADY ON MAIN
Hidden-state fix stacked on migration and ACK compatibility. On main via `e228e65` (#125). Hidden, migration, and legacy tests identical; ACK-drain remainder as in recall-ack-drain above.

### preserve/codex/recall-history-owner-20261015 — ALREADY ON MAIN
History fix stacked on the same migration and ACK base. On main via `9831d1d` (#127). `lib/features/review/data/recall_api.dart` and all lane tests identical.

### preserve/codex/recall-history-pagination-overnight-20261011 — ALREADY ON MAIN
Counts daily introductions across capped history pages. Pagination test identical on main; `recall_api.dart` on main has 7 more lines (later work).

### preserve/codex/recall-local-prefs-20261014 — ALREADY ON MAIN
Isolates persisted review preferences from the shared cache. On main via `c0eb8c7` (#109). Library and test files identical.

### preserve/codex/recall-migration-ack-20261015 — ALREADY ON MAIN
Owner migration stacked on deterministic legacy-refusal and ACK compatibility. Migration and legacy tests identical on main; ACK-drain remainder as in recall-ack-drain above.

### preserve/codex/recall-migration-native-view-20261014 — PARTLY
Owner migration with native-cache binding, quota recovery, and platform write-failure views. The retry core is on main via `ad85e32` (#124); `test/local_owner_migration_retry_test.dart` matches exactly. Missing is the native/quota follow-up. Missing paths:
- `lib/features/review/data/local_review_write_failure_stub.dart`
- `lib/features/review/data/local_review_write_failure_web.dart`
- `test/local_owner_migration_native_cache_test.dart` (214 lines)
- `test/local_review_native_retry_test.dart` (577 lines)
- `test/local_review_quota_classifier_web_test.dart` (84 lines)
- the `_write` wrapper hunk in `lib/features/review/data/local_review_preferences.dart` (branch has 28 more lines; main `lib/` has no quota symbols)
- quota sign-out cases in `test/signout_isolation_test.dart` (branch has 108 more lines, e.g. quota recovery and rejected-quota ratings)

### preserve/codex/recall-migration-retry-20261014 — ALREADY ON MAIN
Releases idle owner migration queues and reads durable migration state safely. Retry test identical on main; claim test on main is a superset. On main via #124.

### preserve/codex/recall-native-offline-restart-20261014 — ALREADY ON MAIN
Qualifies native offline review recovery across restart with framing diagnostics. On main via `9b463d4` (#114). All lane test files identical.

### preserve/codex/recall-offline-roundtrip-20261014 — ALREADY ON MAIN
Covers offline rating persistence and reconnect replay in one end-to-end test. On main via `cbd1726` (#111). File identical.

### preserve/codex/recall-overnight-integration-20261011 — ALREADY ON MAIN
Composite lane (PWA retirement docs, rating, history, sign-out, Undo isolation). Each part is on main via #94, #95, #98, #103. `test/recall_test.dart` (6401 lines) is obsolete: main split it into feature suites in `ccd1a24` (#108).

### preserve/codex/recall-performance-measurements-20261014 — ALREADY ON MAIN
Measures synthetic flow and Android cold start with deck-selection coverage. On main via `775cc71` (#112). Performance test identical; deck-selection test on main is a superset.

### preserve/codex/recall-pwa-retirement-overnight-20261011 — ALREADY ON MAIN
Retires the built-in PWA build and documents Android and Hub as supported clients. On main via `8b1c5b8` (#95) and `de5a11e` (#96). `test/recall_test.dart` obsolete as above.

### preserve/codex/recall-rating-isolation-20261012 — ALREADY ON MAIN
Isolates rating writes and queue effects by session. Same change as recall-action-isolation. Test on main with later additions.

### preserve/codex/recall-rating-tail-fix-20261012 — ALREADY ON MAIN
Resets catch-up rating progress across midnight with tail-race coverage. On main via #104. All 5 test files identical.

### preserve/codex/recall-reliability-integration-20261011 — ALREADY ON MAIN
Bundles hidden, sign-out, and rating isolation. All lane tests are on main as identical files or supersets.

### preserve/codex/recall-reload-split-20261013 — ALREADY ON MAIN
Fences durable ratings across reloads and blocks Undo during persistence. On main via #103 and `0d514a5` (#102). Both test files identical.

### preserve/codex/recall-sharpen-20261011 — ALREADY ON MAIN
Limits validation to Android and web and clears the visual fixture override. On main via `a2f0a64` (#94). `test/recall_test.dart` obsolete as above.

### preserve/codex/recall-signout-isolation-20261011 — ALREADY ON MAIN
Preserves pending study actions during sign-out with session isolation. On main via `44dd773` (#98); sign-out suite on main is a superset.

### preserve/codex/recall-signout-isolation-20261012 — ALREADY ON MAIN
Scopes sign-out barriers and producer draining to the auth session. `test/signout_isolation_test.dart` matches main exactly (814 lines).

### preserve/codex/recall-storage-api-fixtures-20261014 — ALREADY ON MAIN
Covers secure storage and RPC transport failure boundaries. On main via `eaed281` (#113). Both test files identical.

### preserve/codex/recall-store-ack-fix-20261012 — ALREADY ON MAIN
Serializes catch-up reads behind native acknowledgements. On main via `7cdab04` (#100). Serialization test identical.

### preserve/codex/recall-undo-isolation-overnight-20261011 — ALREADY ON MAIN
Keeps delayed Undo in its original session with hidden, sign-out, and rating isolation. Undo test identical on main; the rest are supersets.

### preserve/codex/recall-undo-owner-20261015 — ALREADY ON MAIN
Keeps delayed Undo in its original owner and session. On main via `1b9142e` (#126). `review_controller.dart` matches main exactly (2421 lines); Undo, hidden, and migration tests identical.

### preserve/codex/recall-undo-rating-interlock-20261013 — ALREADY ON MAIN
Prevents Undo during rating persistence. On main via #102. `test/rating_undo_ack_race_test.dart` identical.

### preserve/codex/retire-built-in-pwa-20261012 — ALREADY ON MAIN
Retires the built-in PWA build and Pages publisher, preserving legacy app identity. On main via #95. `test/app_switcher_test.dart` identical; CI test on main is a superset.

## Counts

- ALREADY ON MAIN: 31
- PARTLY: 2
- NOT ON MAIN: 0

## Follow-ups worth finishing (one PR each)

1. **Committed-rating independence for catch-up reads** (from `preserve/codex/recall-catchup-persisted-read-20261015`): port `test/catch_up_committed_rating_progress_test.dart` and its `review_controller.dart` hunk so committed ratings stay independent of failed native progress reads, midnight rollover, owner replacement, Undo, and peer progress.
2. **Native retry and quota-refusal classification for owner migration** (from `preserve/codex/recall-migration-native-view-20261014`): port the stub/web write-failure shims, the `_write` wrapper in `local_review_preferences.dart`, the native-cache, native-retry, and quota-classifier tests, and the quota sign-out cases, so proven browser quota refusals retire cleanly while unknown errors stay uncertain.

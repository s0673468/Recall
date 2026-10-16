# Held storage PRs triage — 2026-10-16

Three high-risk PRs are on `hold`: #119, #110 and #106.
This report compares each change with `main` (tip `c116c05`, #130)
and with `origin/pr-129b` (contract B, in progress).
No fetch was done. All four branches were already in this clone.

Main merged these PRs as squash commits, so commit ids do not match.
Each verdict compares the code itself: the same functions, the same lines,
and the same test files.

Contract B means: an action the device refused to save is never shown and never synced.

## Summary

| PR | Verdict | Conflicts with contract B? | Action |
|----|---------|----------------------------|--------|
| #119 | SUPERSEDED by main (#121, #122) | No | Close as superseded |
| #110 | PARTIAL: store work is in #129; one CI step is missing | Yes, as written | Close after #129 merges; port the CI step |
| #106 | SUPERSEDED by main (#124) | No | Close as superseded |

## #119 — Drain only server-acknowledged review and flag identities

**Verdict: SUPERSEDED by main.**

The change replaces "remove the first N delivered rows" with "remove only the
rows the server acknowledged, matched by identity". Main already does this:

- `lib/features/review/application/review_controller.dart:_flushOnce` and
  `_flushFlagsOnce` are the same as #119's code. They collect `acknowledged`
  rows, skip ambiguous identities, and call `removeAcknowledgedReviews` /
  `removeAcknowledgedFlags`.
- `lib/features/review/data/local_review_store.dart` on main has
  `removeAcknowledgedReviews`, `removeAcknowledgedFlags`, `_removeAcknowledged`,
  `reviewDeliveryId` (legacy card + time + device key), `uniqueDeliveryIds`,
  `_sameAcknowledgedPayload` and `_decodeList`.
  Main's `_removeAcknowledged` does more than #119's: it also merges the
  shared-cache copy (`_mergeUnacknowledged`).
- Tests: `test/cross_tab_server_ack_drain_test.dart` and
  `test/legacy_review_delivery_upgrade_test.dart` match main once whitespace
  is ignored. The controller-level test in #119's
  `test/local_server_ack_drain_test.dart` ("unidentified or duplicate events
  never reach transport") is on main in
  `test/server_ack_transport_admission_test.dart`.
- #119's `tool/` and native-cost workflow edits only re-pin hashes for
  #119's own store file. Those pins are out of date now.

**Contract B:** no conflict. #119 writes only from native storage and never
merges cache-only rows. Main's version (#122) does merge cache-only rows, and
#129 adds the `_refusedIds` tombstones to stop refused rows from going through
that merge. That is #129's job, not #119's.

**Action:** close #119 as superseded by #121 and #122.

## #110 — Preserve migrated reviews when the tab cache is stale

**Verdict: PARTIAL.** The app-code part is in `origin/pr-129b`.
One CI step is not in main or in #129.

#110 contains three things:

1. The #106 owner-migration retry. Main already has this through #124 (see #106 below).
2. Native-truth reads and a refusal-aware append path. `origin/pr-129b` has
   all of this, and more:
   - `local_review_preferences.dart`: `LocalPreferenceWriteNotCommitted` and
     `_write` are in #129, and #129's version also reloads the shared cache
     after a definite refusal.
   - `local_review_store.dart`: the `_prefs` snapshot getter,
     `_retryableAppends` / `_uncertainAppends`, `_appendProducer`,
     `_settleVisiblePending`, `_pendingCount`, `_removeOutboxForClear`,
     `_dropPendingId` / `_dropDrainedIds`, and the changes in `removeEntry`,
     `removeFlagEntry` and `markReviewAttempted` are all in #129 with the same logic.
   - `local_review_write_failure_stub.dart`, `local_review_write_failure_web.dart`,
     the `shared_preferences_web: 2.4.3` pin in `pubspec.yaml`,
     `test/local_owner_migration_native_cache_test.dart` and
     `test/local_review_quota_classifier_web_test.dart` are byte-identical in #129.
   - The `test/signout_isolation_test.dart` additions match #129 apart from formatting.
3. Tooling: a CI step, native-cost hash re-pins, and a fixture teardown change.

**Still missing (not on main, not in #129):**

- `.github/workflows/ci.yml`: the step "Test browser quota classification".
  It runs `test/local_review_quota_classifier_web_test.dart` on Chrome.
  That test is marked `@TestOn('browser')`, so the normal `flutter test` job
  skips it. Without this step, nothing in CI runs it after #129 merges.
  This does not conflict with contract B; it only tests the classifier #129 uses.

**Not worth porting:**

- `tool/native_checkpoint_contract.py`, `tool/fixtures/synthetic_native_outbox_cost_main.dart`,
  `tool/measure_android_cold_start.py`, the native-cost workflow and
  `tool/tests/test_native_checkpoint_cost.py`: these pin #110's own store hash
  and are out of date. Side note for #129: main pins the store blob
  `677f35e`, and #129 changes the store. That workflow only runs when `tool/`
  paths change, so it stays quiet until someone edits those paths. Then it
  needs new pins.
- `tool/fixtures/synthetic_recall_flow.dart:dispose` (wait for the background
  sender before teardown). This only fixed a test flake on #110's branch.
  Port it only if that flake shows up on main.

**Contract B: #110 as written conflicts with it.**

- `_appendProducer` keeps a refused append in `_retryableAppends` and adds it
  again on the next append. #110 has no tombstone and no controller step that
  throws it away. So a refused rating can be saved later and synced next to
  the user's redo.
- `test/local_review_native_retry_test.dart` in #110 expects the refused value
  to stay in the shared cache (`contains('quota-rejected')`). #129 expects
  it to be gone (`isNot(contains('quota-rejected'))`).
- #129 fixes both problems with `_refusedIds` / `_tombstoneRefused`, the
  cache reload in `LocalReviewPreferences._write`, and
  `ReviewController._discardRefused`. Merging #110 on top of #129 would bring
  back the old expectation.

**Action:** do not merge #110. Close it as superseded once #129 merges.
After that, port only the Chrome CI step in a small follow-up PR (or add it
to #129 before it merges).

## #106 — Retry owner migration without replacing pending settings

**Verdict: SUPERSEDED by main (#124).**

- `lib/features/review/data/local_review_store.dart`: main has the same
  `_ownerMigrationTail` and `_withOwnerMigrationLock`, line for line.
  `activateOwner` on main does the same retry from acknowledged storage, inside
  both locks.
- The only code difference is how persisted values are read. #106 calls
  `SharedPreferencesStorePlatform.instance.getAll()` and adds the `flutter.`
  prefix by hand. Main calls `LocalReviewPreferences.readSnapshot` (from #109),
  which does the same read in one shared helper.
- `pubspec.yaml`: #106 moves `shared_preferences_platform_interface` into
  normal dependencies. Main already has it there.
- All four tests (`local_owner_migration_retry_test.dart`, `_claim_race_test.dart`,
  `_settings_race_test.dart`, `_zone_test.dart`) are on main. Ignoring
  whitespace, the only differences are line wrapping, plus a few extra lines
  in main's claim-race test.

**Contract B:** no conflict. This change is about owner migration only.
It has no refused-append handling.

**Action:** close #106 as superseded by #124.

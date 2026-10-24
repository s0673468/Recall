# Synthetic Android outbox checkpoint cost

This fixture compares one **frozen, generated-data** baseline with one experimental checkpoint-drain Controller hunk. It is a debug-emulator experiment, not a production benchmark. The workflow is `.github/workflows/recall-synthetic-native-cost.yml` (`Synthetic native outbox checkpoint cost`); its `synthetic-native-cost` job runs on GitHub-hosted Ubuntu when the listed synthetic fixture, driver, test, or workflow paths change on a push or pull request to `main`. It has no scheduled or manual trigger. The job builds two isolated APKs under `com.german.recall.syntheticbenchmark`, then uses one disposable x86_64 Android emulator for four fresh processes: baseline with 128 and 512 pending generated reviews, followed by checkpoint with 128 and 512. Each case clears only the benchmark package and gets a distinct PID.

The source profile is deliberately exact. The configured baseline reference is the pre-merge PR commit `1a38bb4be3ffff66da4204fa5bcb341e4c92698e`; the current merged byte profile binds Controller SHA-256 `785c1cc281059722df498561501fd392c701b09c5572de5d0fcc76582ef576f0`, Store SHA-256 `74b2d7e24f91a8dc32d0075692b5d098d6fb67e7e7a8cd29329112a3e4d0fd83` (Git blob `6b971b395d5b63b82cdf66134667e0eedb50ee30`), checkpoint-only patch SHA-256 `12b80894e29cccf1fbb9366def4ebeea1ca831fe761cd0c7e2ba252b80a7f902`, resulting Controller SHA-256 `20bdd44241c133878e100fc44a469456c54a74b77508ea7d13ed25226f214dbf`, and this fixture entrypoint SHA-256 `f849a1ea9453cabe8e3d5aad87d2b47d21405b02c8f19d6534750fd2611084fd`. The generated pending reviews use the same 15-field payload and fake `.invalid` HTTP in both variants. The checked-out harness commit is the **current** `$GITHUB_SHA`, passed as `RECALL_SOURCE_COMMIT`; it is intentionally different from `RECALL_BASE_COMMIT=1a38bb4b...`, the frozen baseline reference. The preparer verifies both bindings and copies only technical source into new runner-temporary directories. It never replaces the production Controller or Store.

The workflow's source preparation and driver correspond to these commands (the workflow supplies fresh `$COST_SOURCE` and `$COST_RESULTS` paths under `$RUNNER_TEMP`):

```sh
python3 tool/prepare_native_checkpoint_cost.py --source "$GITHUB_WORKSPACE" --destination "$COST_SOURCE/baseline" --source-commit "$GITHUB_SHA" --variant baseline --patch tool/fixtures/checkpoint-drain-only.patch --fixture-sha f849a1ea9453cabe8e3d5aad87d2b47d21405b02c8f19d6534750fd2611084fd > "$COST_RESULTS/base-provenance.json"
python3 tool/prepare_native_checkpoint_cost.py --source "$GITHUB_WORKSPACE" --destination "$COST_SOURCE/checkpoint" --source-commit "$GITHUB_SHA" --variant checkpoint --patch tool/fixtures/checkpoint-drain-only.patch --fixture-sha f849a1ea9453cabe8e3d5aad87d2b47d21405b02c8f19d6534750fd2611084fd > "$COST_RESULTS/checkpoint-provenance.json"
python3 tool/run_native_checkpoint_cost.py --source-commit "$GITHUB_SHA" --baseline-apk "$COST_SOURCE/baseline/build/app/outputs/flutter-apk/app-debug.apk" --checkpoint-apk "$COST_SOURCE/checkpoint/build/app/outputs/flutter-apk/app-debug.apk" --baseline-provenance "$COST_RESULTS/base-provenance.json" --checkpoint-provenance "$COST_RESULTS/checkpoint-provenance.json" --output "$COST_RESULTS/native" --phase-timeout 90
```

The two `flutter build apk --debug` invocations between preparation and driver execution target `tool/fixtures/synthetic_native_outbox_cost_main.dart`. Each embeds the seven fixed compile defines shown in the workflow: synthetic enablement, current source commit, frozen base commit, variant, matching Controller hash, matching patch hash (or `none`), and fixture hash. Pending count is selected at launch by the Android route extra `/recall-outbox-cost/128` or `/recall-outbox-cost/512`, not by rebuilding. The driver checks APK package identity and source provenance before installation, then accepts one strict #114 chunk-framed receipt per process. A refused guard, incomplete frame, wrong source hash, missing case, failed fake RPC, or non-empty native outbox is a **failed experiment**, not a data point.

`$COST_RESULTS/native/comparison.json` is the closed four-case result. For each case, `sync_pending` times one awaited real `ReviewController.syncPending()` call after generated seeding. `mark_total` and `remove_total` time the corresponding real Store methods; `native_ack_total` and `native_ack_max` time successful awaited writes to the **owner-scoped review-outbox key only** through a delegate to the real Android preferences plugin. `api_apply_total` times real `RecallApi.applyReview` calls through fake `MockClient` responses. These intervals overlap: Store durations include their native writes, API and Store work lies inside `sync_pending`, and `native_ack_max` is a member of the ACK total. **Do not add the timing fields.** Both variants carry the production batched delivery mark (#136): the first send is marked alone and, once acknowledged, the rest of the drain in one batch write. So every case must report `mark_calls` 1 and `native_ack_writes` equal to 2 plus its removal writes (1 for baseline, count/32 for checkpoint); the fixture also requires exactly one batch mark. Compare like-for-like cases and inspect write counts, UTF-8 bytes, acknowledgements, and completion checks alongside elapsed time. Each of the four sizes/variants runs once; the output is not a statistical distribution.

The workflow retains only `base-provenance.json`, `checkpoint-provenance.json`, and `native/comparison.json` as an Actions artifact for **two days**. Raw logcat stays in memory and is not uploaded. The receipts contain closed technical fields and numeric counts/timings, never generated card text. The fake origin and isolated emulator exercise no real provider, account, physical device, release build, radio path, or power-loss test. An Android preference acknowledgement means its delegate returned success; it does not prove fsync or post-power-loss durability. A successful workflow establishes only this pinned debug-emulator comparison, with no production or general Android speedup claim.

If a later main Controller, Store, patch, fixture, or technical source copy fails a pin, treat it as a **profile refusal**. Qualify a new deliberate experiment against the new source and update the pins, test contract, and interpretation together. Never weaken a pin to force a run or restore old production source over current work. Applying the checkpoint optimization to production remains held behind the #109 → #110 correctness chain and its own exact-head gates.

Recall#164 re-pins this profile against merged base `0836af8`, combining its incremental counters and cheaper catch-up with main's Recall#161 changes (merged at `843dfb0`): hidden-card sync paging, stale pending-count fixes, and undo-count changes. The regenerated three-hunk patch changes only its line positions; its checkpoint-drain additions and removal are identical to main's experiment. Store contents, generated workloads, and required write/completion counts are unchanged. The fixture changes only its embedded source guards. Receipts from previous profiles do not qualify this profile; fresh four-case emulator results are required before interpreting its timings. This re-pin establishes no new timing result.

Recall#171 refreshes the profile against safety-fix commit `6605cce`, including the Controller's account/session and offline Undo protections and the Store's duplicate-delivery Undo protections. Both source files now have new pins. The checkpoint patch changes only its three hunk positions; its additions and removal are byte-for-byte unchanged. The fixture changes only its source guards. Generated workloads and required write/completion counts are unchanged. Previous receipts do not qualify this profile; this refresh establishes no new timing result.

Recall#171 re-pins the profile again against review-fix commit `44f71d0` after the latest study-session fix. Only the three checkpoint hunk positions and source guards change; the patch additions/removal, Store, generated workloads, and required write/completion counts are unchanged. Superseded receipts remain refused; this re-pin establishes no new timing result.

Recall#172 re-pins the profile against offline-retry fix `d360f61`. Only the Store pin, base commit, and derived fixture guards change. The Controller and checkpoint patch (including hunk positions and additions/removal) are byte-for-byte unchanged, as are generated workloads and required write/completion counts. Superseded receipts remain refused; this re-pin establishes no new timing result.

Recall#175 re-pins the profile against offline-sync fix `295d397`. The three checkpoint hunks change only their positions; their additions/removal, the Store, generated workloads, and required write/completion counts are unchanged. The Controller and derived fixture guards use the new profile. Superseded receipts remain refused; this refresh establishes no new timing result. Fresh four-case emulator results are required before interpreting timings.

Recall#179 re-pins the profile against offline deck-count commit `34fc5786ea432090a09d62249f731b8488bec809`. Only the Store pin, base commit, and derived fixture guards change. The Controller and regenerated checkpoint patch (including hunk positions and additions/removal) are byte-for-byte unchanged, as are generated workloads and required write/completion counts. Superseded receipts remain refused; this refresh establishes no new timing result. Fresh four-case emulator results are required before interpreting timings.

Recall#179's review correction refreshes the Store and derived fixture byte pins
after separating uncertain delivery from confirmed count coverage. The Controller,
checkpoint patch, generated workloads, and required write/completion counts are
unchanged. The corrected source reference is `ec18dcf195182ccecaa16ed767e5c6a60daf3c1a`. Previous
receipts remain refused. This correction establishes no new timing result; fresh
four-case emulator results are required before interpreting timings.

To refresh this profile after a deliberate source change:

1. Set `native_checkpoint_contract.SOURCE` to the full commit containing the new Controller and Store. Compute `BASE_CONTROLLER` and `STORE_SHA` as the SHA-256 of their file bytes. Compute `STORE_BLOB` as the Git blob ID (`git hash-object lib/features/review/data/local_review_store.dart`).
2. Reapply the three checkpoint-only hunks to a temporary Controller copy. Regenerate `checkpoint-drain-only.patch` against the new Controller, retaining its existing additions/removal and updating hunk positions and context as needed. Set `PATCH_SHA` to the patch's SHA-256 and `CHECKPOINT_CONTROLLER` to the resulting temporary Controller's SHA-256. Never modify the production Controller for this experiment.
3. Update the synthetic entrypoint's `_baseCommit` guard, both Controller guards, `_storeBlob`, and `_checkpointPatchSha`. Then compute `FIXTURE_SHA` from the updated entrypoint's file bytes; the fixture hash is passed at build time and is not embedded into its own source.
4. Synchronize the workflow's preparation arguments and build defines, the independent patch-pin expectation in `test_native_checkpoint_cost.py`, and the documented pins above. Preserve historical refusal fixtures and extend refusal coverage for the superseded profile. Run the source-pin and native-checkpoint tool tests, then the normal repository checks. Fresh four-case emulator results are still required to interpret timings.

The shared Android build input has a separate exact-byte pin in `measure_android_cold_start.BASE_GRADLE_SHA`, used by the cold-start, native-offline and checkpoint preparers. After a deliberate `android/app/build.gradle.kts` change, inspect its diff, compute `sha256sum android/app/build.gradle.kts`, and update that pin. Confirm `isolated_gradle()` rewrites exactly one application ID and preserves every other byte; keep refusal coverage for changed input and missing or duplicate IDs. Run `python3 -m unittest discover -s tool/tests`, `PYTHONPATH=. python3 -B test/test_synthetic_native_prepare.py`, and `python3 tool/measure_android_cold_start.py self-test`, then the normal repository checks. A Gradle-only refresh does not change the frozen Controller/Store profile or qualify new timing results.

Recall#176 refreshes the Gradle pin to `ea553273c9ddc2a8870cc6ba411a55eef3976d74a6662da35896ca8ddcd73277` after the reminders fix added the Robolectric unit-test dependency. Application behavior, source-isolation guards and the frozen checkpoint experiment are unchanged. The superseded Gradle source remains refused.

The likes feature refreshes the current Controller/Store byte profile and the
checkpoint hunk positions. The frozen baseline reference, experimental edits,
generated workload, and required completion counts remain the same. This
refresh establishes no new timing result.

Recall#183's review correction re-pins the profile against `bae90089cb6b9fe3f2eb66513d84a9bb11ad0c5a`.
The Controller now reconciles likes at delivery, and the Store verifies the
complete withdrawal payload after an uncertain write. Both byte pins and the
fixture guards are refreshed. The three checkpoint hunks change only their line
positions; their contexts, additions and removal are byte-for-byte unchanged.
Generated workloads and required write/completion counts remain unchanged.
Superseded receipts remain refused. This refresh establishes no timing result;
fresh four-case emulator results are required before interpreting timings.

Recall#184 refreshes the profile against daily-count review fix `3e64b782e2b86e422bd15fcc9e767390dd2df081`. The checkpoint variant now persists accepted daily-review receipts before each batch removal, preserving the production durability ordering. Controller, patch and derived fixture guards are refreshed; Store and derived guards include the daily-review cache and shared writer lock; generated workloads and required outbox write/completion counts are unchanged. Superseded receipts remain refused. This refresh establishes no timing result; fresh four-case emulator results are required before interpreting timings.

Recall#184’s merge resolution combines the daily-count branch with main’s
Recall#183 likes and withdrawal recovery. The frozen reference is the pre-merge
PR head `1a38bb4be3ffff66da4204fa5bcb341e4c92698e`; the exact Controller, Store,
patch and entrypoint hashes above bind the combined working source, while
`RECALL_SOURCE_COMMIT` identifies the eventual checked-out merge commit. The
regenerated three-hunk checkpoint patch retains daily-review receipt persistence
before every batch removal. Both parents’ superseded byte profiles remain
refused, and the offline restart regression verifies that cached likes and
daily counts restore together. No timing result is established by this merge.

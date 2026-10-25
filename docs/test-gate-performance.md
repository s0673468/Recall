# Test gate performance

Continuation validation for Recall test-gate throughput, 2026-10-25.
The unverified WIP's timing tables have been replaced with measurements from
this checkout. No hosted workflow or PR was dispatched.

## Change and coverage

Keep the WIP's four whole-file Flutter shards, timing-based balancing and
expensive-file-first order. Test-source SHA-256 and the Flutter version must
match before using a stored cost. New or edited tests use source size scaled
by valid timings; missing, stale or other-SDK profiles fall back to size.
Malformed profiles stop the shard listing before Flutter runs.
`--no-timings` reproduces the pre-WIP source-size partition and file order.
Timing data never selects or excludes tests.

Keep `analyze --no-pub` after the existing dependency resolution, and install
CPU-only PyTorch before the optimizer's unchanged requirements. The local
optimizer suite passes with FSRS 6.1.1 and Torch 2.14.1+cpu. CUDA dependencies
are unnecessary on the hosted CPU runner; no dependency-install speedup was
measured here.

The continuation fixes an uncaught `OverflowError` for oversized JSON integer
durations. It now becomes a normal manifest validation error. Three added
regressions cover that error, ignoring malformed data in baseline mode, and
ignoring obsolete rows after an SDK mismatch. The oversized-integer regression
was confirmed to error against the unmodified WIP and pass after the fix.
All eleven WIP regressions remain: measured weighting, hash/SDK fallback,
discovery after file changes, actual workflow shell execution, failure
propagation and the required check's dependency results.

Both matrices passed **1,637 tests with the same four existing exclusions**.
The tooling suite ran **216 cases with its one existing retired-Apple exclusion**,
including all benchmark source pins and the real 34,623-vector VM/JS scheduler
parity check. Existing test assertions, fixtures, benchmark pins and application/native
source are unchanged. No existing test was edited, deleted or newly excluded.
Tests use synthetic fixtures and fake transports; no real account, personal
study data, credentials or external test service was used. No iOS build or
validation ran.

## Measurement method

Flutter 3.47.1 / Dart 3.13.1, the Python 3.12.3 environment, Android SDK,
Chrome, package caches, Java user state and temporary files were isolated in
this checkout. The installed JDK 17 was used read-only. Flutter was
provisioned from its exact pin into `.tools/flutter-3.47.1`; the maintained
Android SDK and Chrome installations were copied into `.tools` before use.
Android SDK platform 37 was installed in that copy. Setup/download time is
outside the measurements below.

Every baseline shard ran sequentially, followed by every candidate shard,
using **two Flutter workers** on this shared box. No Python suite or native
build overlapped the comparison. SDK/package caches stayed warm. Before each
shard, only this task's disposable `build/test_cache` was removed so later
shards could not reuse the earlier shard's incremental compiler dill.
No `flutter clean` was used.

The stored advisory timing manifest remains the WIP's four-worker profile.
All 201 stored test hashes match this checkout; new/unprofiled files still run.
Its original raw logs were unavailable, so its numeric costs are not presented
as independently verified measurements. The complete successful comparison
below verifies the resulting partition with two workers. Hosted CI retains
four workers per runner; these local times do not measure hosted queue/setup
time or establish an end-to-end merge latency improvement.

## Flutter before and after

JSON reporter `done.time` supplies test-run time. Command wall time additionally
includes the pinned-SDK wrapper and Flutter startup. On separate hosted runners
the test lane's critical path is its slowest shard plus setup/queue time; the
sum of sequential local commands is **not** hosted elapsed time.

| Matrix | Per-shard test-run seconds | Slowest shard | Sum of test-run seconds |
| --- | --- | ---: | ---: |
| Before: 3 source-size shards | 55.910, 54.210, 54.196 | 55.910 s | 164.316 s |
| After: 4 timing-based shards | 33.042, 40.617, 44.747, 42.465 | 44.747 s | 160.871 s |

The measured test-run critical path falls **20.0%**. Aggregate test-run time
falls 2.1%; the fourth shard increases hosted setup and runner usage, which
are outside this comparison.

| Matrix | Per-shard command wall seconds | Slowest command | Sum of commands |
| --- | --- | ---: | ---: |
| Before | 58.211, 55.427, 55.275 | 58.211 s | 168.913 s |
| After | 34.081, 41.406, 45.806, 43.515 | 45.806 s | 164.808 s |

The slowest local command is **21.3% shorter**.

## Twenty slowest Flutter files

Ranked by baseline duration, from each JSON `suite` event through its last test
completion. This includes loading/compilation, setup, bodies and teardown.
Concurrent file intervals overlap and depend on compiler warmup and ordering;
the rows must not be summed or treated as isolated per-test speedups.

| File (`test/`) | Before (s) | After (s) |
| --- | ---: | ---: |
| `android_accessibility_test.dart` | 16.977 | 12.047 |
| `android_sync_recovery_hunt_test.dart` | 13.208 | 0.703 |
| `app_switcher_test.dart` | 9.545 | 0.983 |
| `web_shell_test.dart` | 8.760 | 9.439 |
| `background_outbox_read_failure_test.dart` | 7.625 | 0.815 |
| `android_config_test.dart` | 7.456 | 0.430 |
| `reading_visual_acceptance_test.dart` | 6.795 | 6.896 |
| `acknowledged_cached_flags_test.dart` | 6.582 | 0.620 |
| `production_scale_acceptance_test.dart` | 5.985 | 9.214 |
| `app_unlock_policy_test.dart` | 5.558 | 10.169 |
| `decks_lazy_list_test.dart` | 5.180 | 5.046 |
| `ux_accessibility_hunt_test.dart` | 4.994 | 4.672 |
| `recall_revalidation_holdout_test.dart` | 4.849 | 13.048 |
| `card_quality_tool_test.dart` | 4.036 | 3.014 |
| `recall_read_tab_test.dart` | 3.996 | 7.130 |
| `study_flow_polish_test.dart` | 3.763 | 3.788 |
| `study_flow_browser_acceptance_test.dart` | 3.652 | 4.066 |
| `card_face_test.dart` | 3.564 | 2.708 |
| `concept_primer_extra_figures_test.dart` | 3.521 | 1.246 |
| `quiet_settings_test.dart` | 3.182 | 2.411 |

## Python tooling profile

`--durations 0` measures each unittest including setup/teardown. The full
`tool/tests` command took 6.426 s wall time (6.215 s in unittest), with all
216 cases accounted for and the one unchanged exclusion. No baseline Python
speedup is claimed: existing test bodies and benchmark inputs are unchanged.

| Tool unittest case | Seconds |
| --- | ---: |
| `test_scheduler_build.SharedSchedulerBuildTest.test_compiled_engine_matches_every_synthetic_vm_vector` | 4.565 |
| `test_mutation_sweep_lock.MutationSweepLockTest.test_completion_and_failures_release_ownership` | 0.281 |
| `test_ci_gate_execution.CiGateExecutionTests.test_four_hosted_shards_run_every_file_once` | 0.131 |
| `test_mutation_sweep_recall.MutationSweepTest.test_test_failure_is_distinguished_from_compilation_and_timeout` | 0.115 |
| `test_flutter_shard_timings.TimingShardTests.test_invalid_durations_and_malformed_manifests_fail_closed` | 0.115 |
| `test_mutation_sweep_lock.MutationSweepLockTest.test_owner_excludes_other_phases_and_batches_until_restored` | 0.112 |
| `test_mutation_sweep_lock.MutationSweepLockTest.test_termination_restores_source_and_releases_ownership` | 0.083 |
| `test_bootstrap_flutter.BootstrapFlutterTest.test_install_is_atomic_and_idempotent` | 0.081 |
| `test_mutation_sweep_lock.MutationSweepLockTest.test_owner_excludes_competitors_during_baseline` | 0.072 |
| `test_flutter_test_shards.ShardTests.test_repository_shards_partition_every_test_file` | 0.068 |
| `test_ci_gate_execution.CiGateExecutionTests.test_failed_listing_never_launches_flutter_and_failed_tests_fail_the_job` | 0.066 |
| `test_bootstrap_flutter.BootstrapFlutterTest.test_fresh_sdk_is_primed_before_machine_metadata_is_validated` | 0.046 |
| `test_bootstrap_flutter.BootstrapFlutterTest.test_wrong_download_is_not_promoted_and_stage_is_removed` | 0.044 |
| `test_flutterw.FlutterWrapperTest.test_malformed_sdk_metadata_is_rejected` | 0.041 |
| `test_flutterw.FlutterWrapperTest.test_exact_environment_sdk_forwards_arguments` | 0.038 |
| `test_flutterw.FlutterWrapperTest.test_cached_sdk_wins_over_path` | 0.038 |
| `test_flutterw.FlutterWrapperTest.test_wrong_environment_sdk_is_rejected` | 0.037 |
| `test_mutation_sweep_recall.MutationSweepTest.test_termination_unwinds_and_restores_planted_source` | 0.033 |
| `test_affected_tests.GitChangesTests.test_includes_committed_staged_unstaged_untracked_and_both_rename_paths` | 0.028 |
| `test_flutterw.FlutterWrapperTest.test_missing_sdk_has_bootstrap_instruction` | 0.023 |

## Android profile

The unchanged Android debug command passed in 287.126 s with a fresh local
Gradle cache. All four signed/unsigned release-policy probes passed in 47.221 s.
Native unit/lint/instrumentation compilation passed in 139.542 s measured by the
parent monotonic clock. All 38 JVM tests passed with zero failures, errors or
exclusions, verified from all four JUnit XML suites. Instrumentation was compiled,
not run on a device. These serial Android commands total **473.889 s**; no
native speedup is attributed to this change.

A disposable Gradle init listener recorded the twenty longest task executions
in the native command. Task intervals overlap across two workers and exclude
configuration/startup; their sum is not command wall time.

| Android task | Seconds |
| --- | ---: |
| `:app:testDebugUnitTest` | 26.405 |
| `:shared_preferences_android:lintAnalyzeDebug` | 17.569 |
| `:app:compileFlutterBuildDebug` | 17.366 |
| `:app:compileDebugUnitTestKotlin` | 15.986 |
| `:app:generateDebugUnitTestLintModel` | 13.644 |
| `:flutter_secure_storage:lintAnalyzeDebug` | 11.841 |
| `:app_links:lintAnalyzeDebug` | 9.963 |
| `:url_launcher_android:lintAnalyzeDebug` | 8.751 |
| `:app:lintAnalyzeDebug` | 6.705 |
| `:shared_preferences_android:generateDebugUnitTestLintModel` | 6.552 |
| `:app:generateDebugAndroidTestLintModel` | 3.838 |
| `:app:mergeExtDexDebugAndroidTest` | 3.075 |
| `:jni:lintAnalyzeDebug` | 2.852 |
| `:app:lintAnalyzeDebugUnitTest` | 2.529 |
| `:app:generateDebugAndroidTestGlobalSynthetics` | 1.822 |
| `:url_launcher_android:generateDebugUnitTestLintModel` | 1.591 |
| `:shared_preferences_android:lintAnalyzeDebugUnitTest` | 1.591 |
| `:app:configureCMakeDebug[arm64-v8a]` | 1.415 |
| `:app:configureCMakeDebug[armeabi-v7a]` | 1.391 |
| `:app:configureCMakeDebug[x86_64]` | 1.362 |

The listener was supplied only for profiling, without changing task selection,
application sources or assertions:

```groovy
// build/test-speed/task-timings.gradle
def started = new java.util.concurrent.ConcurrentHashMap<String, Long>()
gradle.taskGraph.beforeTask { task -> started[task.path] = System.nanoTime() }
gradle.taskGraph.afterTask { task, state ->
    def elapsed = (System.nanoTime() - started[task.path]) / 1000000000.0
    println "RECALL_TASK_TIMING ${task.path} ${elapsed}"
}
```

## Reproduce and verify

Keep mutable state checkout-local and use the pinned SDK. The test comparison
uses the actual repository shard-listing and Flutter commands:

```bash
set -euo pipefail
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export RECALL_FLUTTER_ROOT="$PWD/.tools/flutter-3.47.1"
export DART="$RECALL_FLUTTER_ROOT/bin/dart"
export PATH="$PWD/build/test-speed/venv/bin:$RECALL_FLUTTER_ROOT/bin:$PATH"
export PUB_CACHE="$PWD/.pub-cache"
export TMPDIR="$PWD/build/test-speed/tmp"
export XDG_CONFIG_HOME="$PWD/build/test-speed/config"
export XDG_CACHE_HOME="$PWD/build/test-speed/cache"
export XDG_DATA_HOME="$PWD/build/test-speed/data"
export GRADLE_USER_HOME="$PWD/build/test-speed/gradle"
export ANDROID_USER_HOME="$PWD/build/test-speed/android"
export ANDROID_HOME="$PWD/.tools/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export CHROME_EXECUTABLE="$PWD/.tools/chrome-linux64/chrome"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR -Duser.home=$PWD/build/test-speed/java-home -XX:-UsePerfData"
export GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2 -Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process'
export OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 NUMEXPR_NUM_THREADS=2
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$TMPDIR" build/t build/test-speed/java-home
for total in 3 4; do
  for ((index=0; index<total; index++)); do
    flags=()
    if [[ "$total" == 3 ]]; then flags+=(--no-timings); fi
    rm -rf build/test_cache  # disposable compiler cache created by these runs
    shard_files="$(python3 tool/flutter_test_shards.py --total "$total" --index "$index" "${flags[@]}")"
    /usr/bin/time -p ./tool/flutterw test --reporter=json \
      --exclude-tags apple-mobile --no-pub --concurrency=2 $shard_files \
      > "build/test-speed/flutter-$total-$index.jsonl"
  done
done
```

Recorded command wall times use Python's monotonic clock around subprocess
execution; `/usr/bin/time -p` above is an equivalent way to reproduce them.
The following commands plus the four candidate shards are the maintained
local equivalent of `.github/workflows/ci.yml`. They ran sequentially on the
final code tree. Chromium ran one file in one headless browser; Flutter ignores
`--concurrency` for web tests.

| Lane | Exact command | Result and wall time |
| --- | --- | --- |
| Analyzer | `./tool/flutterw analyze --no-pub` | Exit 0; no issues; 22.860 s |
| Chromium | `env TMPDIR=build/t timeout --signal=INT --kill-after=10s 180s ./tool/flutterw test --no-pub --platform chrome --concurrency=1 --reporter=json test/local_review_quota_classifier_web_test.dart` | Exit 0; 4 passed; 90.340 s |
| Tooling | `python3 -m unittest discover -s tool/tests -p 'test_*.py' --durations 0` | Exit 0; 216 cases, 1 existing exclusion; 6.426 s |
| Concept sync | `python3 -m unittest discover -s tools/recall_sync/tests -p 'test_*.py' --durations 0` | Exit 0; 63 passed; 4.171 s |
| Anki revision | `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py' --durations 0` | Exit 0; 63 passed; 3.619 s |
| Semantic review | `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py' --durations 0` | Exit 0; 36 passed; 0.636 s |
| Flag report | `python3 -m unittest discover -s tools/flag_report/tests -p 'test_*.py' --durations 0` | Exit 0; 13 passed; 0.114 s |
| FSRS optimizer | `python3 -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py' --durations 0` | Exit 0; 8 passed; 4.721 s |
| Android debug | `timeout --signal=TERM --kill-after=10s 900s ./tool/flutterw build apk --debug --no-pub` | Exit 0; APK built; 287.126 s |
| Release policy | `timeout --signal=TERM --kill-after=10s 1400s python3 tool/check_android_release_policy.py` | Exit 0; all four probes passed; 47.221 s |
| Android native | `timeout --signal=TERM --kill-after=10s 1800s ./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2 --init-script "$PWD/build/test-speed/task-timings.gradle"` | Exit 0; 38 JVM tests, lint and instrumentation compilation passed; 139.542 s |

All **15 final gate commands exited 0**, including the four candidate Flutter
shards. Their serial command total is **771.584 s**, excluding SDK/dependency
provisioning and baseline/profiling repeats. This is a local equivalent of the
maintained CI gate, not measured hosted gate duration or a hosted CI receipt.
Raw reporter logs, command arguments/statuses and timing summaries remain in
`build/test-speed/` for this checkout's reviewer; they are disposable task
output, not committed source. Task-created SDK copies, dependency caches and
build artifacts were removed after verification. No server, browser or Gradle
daemon was retained.

## Remaining opportunities

Android build/lint/startup costs remain unchanged. The profile identifies JVM
test startup, plugin lint and repeated Flutter compilation as remaining costs.
The existing instant-backoff fixture already preserves every PostgREST retry
without real waits. Some Python suites also run through Dart wrappers; removing
that duplication needs a separate coverage/ownership decision. Further matrix
expansion and fixture rewrites remain outside this change.

Measure the next hosted run before claiming a full-gate or merge-throughput
improvement: Android and other required jobs can determine the finish time.
The public repository retains hosted runners and its existing caches; no
self-hosted runner or paid service was introduced. No push, PR or remote change
was made; the runner owns the final commit on top of the WIP.

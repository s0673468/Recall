# Test gate performance

PR notes for the Recall test-gate throughput change, measured on 2026-10-24.

## Change and coverage

The hosted Flutter matrix increases from three whole-file shards to four, with
four workers per runner. Shards now use measured per-file loading/body costs
from `tool/flutter_test_timings.json`. A test-source SHA-256 and the Flutter pin
must match before a measured time is used. Each shard starts its most expensive
files first to overlap their compilation and body work. New or edited files
use source size, scaled by the median valid seconds/byte ratio; a missing profile, a different
SDK or no matching hashes falls back entirely to source-size weights. Deleted
profile entries never affect test discovery. `--no-timings` reproduces the old
partitioning for comparisons. The metadata is advisory scheduling data, not a
benchmark or passing-gate receipt: changes to imported application code can
change costs without changing a test file's hash.

File discovery, test assertions, benchmark fixtures and benchmark source pins
are unchanged. The analyzer uses `--no-pub` after dependency resolution. The
optimizer installs CPU-only PyTorch before its unchanged full requirements,
avoiding CUDA/toolkit dependencies on the hosted CPU runner.

Five new Python integration tests execute the actual workflow shell with
synthetic Dart files and a fake Flutter executable. They verify that all four
matrix indices run every file exactly once, refuse an empty shard before Flutter
starts, propagate a failing Flutter exit status, reject unsuccessful dependency
results in the required gate, pass `--no-pub` to analysis, and preserve optimizer
requirements while failing closed if CPU-wheel installation fails. Six additional
timing tests cover measured weighting, the old baseline mode, hash/SDK fallback, malformed
data, and complete discovery after adding, editing, renaming or deleting files.
The existing tests also partition the real repository for one through four shards.

No application code or existing tests changed. Android, browser, Python and
required-check dependencies remain enabled. Existing Apple exclusions remain;
no Apple build, simulator or test was run. Fixtures use synthetic data and fake
transports; no account, production configuration or external test service is used.

## Measurement method

The repository's installed Flutter 3.47.1 / Dart 3.13.1 SDK was copied into the
ignored checkout-local `.tools/sdk/flutter-3.47.1` directory. Dependency, Python,
Android, Chromium, Gradle, Java user-state and temporary directories were also
checkout-local, following the setup in `sync-scheduling-test-hardening.md`.
Python is 3.12.3 with the declared tool dependencies and CPU-only PyTorch; hosted
CI retains its existing Python 3.14/3.13 versions. Numerical thread pools were
bounded to two workers. No hosted workflow was dispatched.

The initial unsharded run passed 1,637 tests with the four existing exclusions.
The final paired comparison waited for the native and Python checks to finish,
then ran every original three-shard command and every candidate four-shard
command sequentially with four workers. SDK and package caches remained warm.
Before **each** shard, only the task-created `build/test_cache` directory was
removed. Flutter initializes its incremental compiler from a dill file there;
sharing it across local shard commands would make later commands artificially
fast compared with independent hosted checkouts. No `flutter clean` was used.
The final advisory profile was recorded from all three successful baseline
shards before running the candidate matrix, without changing any test source.

The JSON reporter supplies elapsed test-run and per-file loading/body times;
`/usr/bin/time -p` supplies command wall time. Provisioning downloads are outside
the paired Flutter comparison. Preliminary warm-cache measurements are excluded
from the before/after figures below.

On independent hosted runners the Flutter-test lane duration is the slowest
shard, plus setup and runner queue time. Sequential local shard command times
must not be summed and described as hosted elapsed time. These measurements do
not establish hosted queue time or an end-to-end merge latency improvement;
Android or another required job may still determine the full gate's finish time.

| Matrix | Per-shard test-run seconds | Slowest shard | Sum of test-run seconds |
| --- | --- | ---: | ---: |
| Before: 3 shards | 33.788, 24.995, 70.645 | 70.645 s | 129.428 s |
| After: 4 shards | 20.665, 44.668, 20.484, 18.320 | 44.668 s | 104.137 s |

The measured Flutter test-run critical path falls **36.8%**. Both matrices
execute the same 1,637 passing tests and 4 existing exclusions.
The command wall times, including SDK verification/startup and any local lock
wait, were 37.99, 29.20, 78.51 s before and
24.90, 48.90, 24.85, 19.43 s after. The test-run clock is
the comparison used above; local startup contention is not a hosted saving.

Command wall time (including the pinned-SDK wrapper and Flutter startup):

| Matrix | Slowest command | Sum of all shard commands |
| --- | ---: | ---: |
| Before | 78.51 s | 145.70 s |
| After | 48.90 s | 118.08 s |

The slowest local command is **37.7% shorter**. Hosted setup, queuing and the
other required jobs are outside this measurement.

## Twenty slowest Flutter files

Each row includes file compilation/loading, setup, test bodies and teardown,
using the interval from the JSON suite event to its last test completion.
Files are ranked by the original three-shard run. Times from concurrently loaded
files overlap, so adding these rows is not a wall-time total.

| File (`test/`) | Before (s) | After (s) |
| --- | ---: | ---: |
| `semantic_review_tool_test.dart` | 11.720 | 5.650 |
| `native_shell_test.dart` | 10.503 | 6.958 |
| `offline_deck_counts_uncertain_ack_test.dart` | 10.204 | 4.859 |
| `mutation_sweep_regressions_test.dart` | 10.132 | 4.262 |
| `recall_revalidation_holdout_test.dart` | 9.843 | 8.239 |
| `recall_decks_stats_screens_test.dart` | 8.474 | 7.942 |
| `app_unlock_policy_test.dart` | 8.082 | 7.685 |
| `android_accessibility_test.dart` | 7.877 | 10.482 |
| `web_shell_test.dart` | 7.553 | 14.234 |
| `recall_read_tab_test.dart` | 7.376 | 10.451 |
| `background_sync_coordinator_test.dart` | 7.240 | 8.064 |
| `recall_api_queue_round_trips_test.dart` | 7.025 | 5.940 |
| `recall_api_null_ack_test.dart` | 6.996 | 8.797 |
| `recall_suspended_test.dart` | 6.965 | 7.124 |
| `recall_visual_benchmark_test.dart` | 6.923 | 10.662 |
| `recall_hidden_sync_paging_test.dart` | 6.882 | 5.279 |
| `recall_ui_widgets_test.dart` | 6.857 | 5.960 |
| `audit_hide_undo_recovery_test.dart` | 6.711 | 0.684 |
| `local_server_ack_drain_test.dart` | 6.611 | 2.943 |
| `recall_prefs_controller_test.dart` | 6.608 | 1.100 |

## Python tooling profile

`--durations 0` records every unittest case, including setup and teardown.
The twenty slowest cases in `tool/tests` are listed below. Those files and the
benchmark inputs are unchanged; differences here are run-to-run variation, not
claimed optimizations. The eleven new regressions increase the suite
from 202 to 213 tests, with its one existing retired-Apple discovery exclusion.
The scheduler still compiles the real engine and verifies all 34,623 VM/JS
vectors, including exact due dates and unchanged floating-point tolerance.

| Tool unittest case | Before (s) | After (s) |
| --- | ---: | ---: |
| `test_mutation_sweep_lock.test_completion_and_failures_release_ownership` | 12.667 | 5.123 |
| `test_mutation_sweep_recall.test_restores_exact_bytes_on_success_failure_and_interrupt` | 6.347 | 0.004 |
| `test_scheduler_build.test_compiled_engine_matches_every_synthetic_vm_vector` | 5.890 | 6.010 |
| `test_mutation_sweep_recall.test_test_failure_is_distinguished_from_compilation_and_timeout` | 5.458 | 2.704 |
| `test_mutation_sweep_lock.test_owner_excludes_other_phases_and_batches_until_restored` | 3.630 | 1.246 |
| `test_affected_tests.test_includes_committed_staged_unstaged_untracked_and_both_rename_paths` | 3.148 | 0.106 |
| `test_mutation_sweep_lock.test_termination_restores_source_and_releases_ownership` | 2.685 | 1.282 |
| `test_mutation_sweep_lock.test_owner_excludes_competitors_during_baseline` | 2.035 | 1.330 |
| `test_mutation_sweep_recall.test_missing_or_ambiguous_match_never_modifies_source` | 1.723 | 0.001 |
| `test_native_offline_driver.test_apk_bytes_changed_after_install_are_refused` | 1.300 | 0.084 |
| `test_mutation_sweep_recall.test_termination_unwinds_and_restores_planted_source` | 1.051 | 1.016 |
| `test_mutation_controller_tap_clock.test_c03_preserves_the_review_entry_and_retry_branches` | 0.473 | 0.106 |
| `test_affected_tests.test_changed_test_and_transitive_test_helper` | 0.403 | 0.176 |
| `test_flutterw.test_invalid_version_file_is_rejected` | 0.328 | 1.191 |
| `test_affected_tests.test_deleted_module_still_selects_its_consumers` | 0.246 | <0.001 |
| `test_native_checkpoint_cost.test_destination_symlink_escape_and_modified_store_refuse_before_copy` | 0.206 | 0.166 |
| `test_native_checkpoint_cost.test_both_variant_technical_copies_preserve_source_and_exclude_data` | 0.086 | 0.547 |
| `test_bootstrap_flutter.test_install_is_atomic_and_idempotent` | 0.079 | 0.068 |
| `test_affected_tests.test_conditional_import_selects_both_platform_consumers` | 0.078 | 0.001 |
| `test_flutter_test_shards.test_repository_shards_partition_every_test_file` | 0.046 | 0.050 |

Total unittest execution: 48.185 s / 202 tests before; 21.970 s / 213 tests
after (one unchanged exclusion in each). Command wall time: 55.46 s before,
28.30 s after. The baseline overlapped initial Flutter compilation, so this
Python difference is not attributed to the change. All benchmark pins pass.

## Android profile

The first debug build with a fresh local Gradle cache took 779.62 s; the
cache-warm verification took 103.92 s. Release-policy probes took 53.88 s, and
unit/lint/instrumentation compilation took 189.76 s. Their serial command total
is 347.56 s. Native sources and task selection are unchanged, so the cold/warm
difference is not attributed to this PR. CI retains its two parallel Android
lanes and hosted-only daemon reuse for release probes. All 38 JVM tests passed
without exclusions; lint and both APK builds passed. Instrumentation was not run
on a device. A disposable Gradle init listener captured the twenty longest task
executions below; its data never enters the source or passing-gate logic.

| Command | Task | Seconds |
| --- | --- | ---: |
| Unit/lint/instrumentation | `:app:testDebugUnitTest` | 46.647 |
| Unit/lint/instrumentation | `:app:compileFlutterBuildDebug` | 24.478 |
| Unit/lint/instrumentation | `:app:compileDebugUnitTestKotlin` | 22.610 |
| Unit/lint/instrumentation | `:shared_preferences_android:lintAnalyzeDebug` | 14.826 |
| Unit/lint/instrumentation | `:app:generateDebugUnitTestLintModel` | 12.882 |
| Unit/lint/instrumentation | `:flutter_secure_storage:lintAnalyzeDebug` | 8.100 |
| Unit/lint/instrumentation | `:app_links:lintAnalyzeDebug` | 7.704 |
| Unit/lint/instrumentation | `:shared_preferences_android:generateDebugUnitTestLintModel` | 7.155 |
| Unit/lint/instrumentation | `:url_launcher_android:lintAnalyzeDebug` | 7.002 |
| Unit/lint/instrumentation | `:app:lintAnalyzeDebug` | 6.944 |
| Unit/lint/instrumentation | `:app:compileDebugUnitTestJavaWithJavac` | 6.533 |
| Unit/lint/instrumentation | `:app:generateDebugAndroidTestLintModel` | 4.114 |
| Debug APK | `:app:compileFlutterBuildDebug` | 4.052 |
| Unit/lint/instrumentation | `:jni:lintAnalyzeDebug` | 2.783 |
| Unit/lint/instrumentation | `:app:mergeExtDexDebugAndroidTest` | 2.688 |
| Unit/lint/instrumentation | `:app:generateDebugAndroidTestGlobalSynthetics` | 1.948 |
| Unit/lint/instrumentation | `:url_launcher_android:generateDebugUnitTestLintModel` | 1.666 |
| Unit/lint/instrumentation | `:app:lintAnalyzeDebugUnitTest` | 1.636 |
| Unit/lint/instrumentation | `:app:configureCMakeDebug[x86_64]` | 1.616 |
| Unit/lint/instrumentation | `:app:configureCMakeDebug[arm64-v8a]` | 1.539 |

Task intervals can overlap and omit configuration/startup; their sum is not a
command wall time. These native timings identify remaining costs, including
JVM startup, Kotlin test compilation and lint. No native test or signing-policy
assertion was removed to reduce them.

## Optimizer dependency setup

The default FSRS resolver was inspected without installing the CUDA stack:
it selected Torch 2.14.1, CUDA toolkit and NVIDIA packages. It announced a
554.6 MB Torch wheel for Python 3.12; the installed same-version CPU wheel is
196.3 MB and needs no CUDA runtime. The official CPU index also supplies a
Python 3.13 Linux x86-64 wheel. All eight optimizer tests, including real fitting
against the synthetic generation, pass with Torch 2.14.1+cpu. No hosted dependency
installation timing or GPU-vs-CPU computation speedup is claimed.

## Reproduce and verify

After preparing the copied pinned SDK and checkout-local caches as above, profile
both matrix sizes with the repository's existing commands:

```bash
set -euo pipefail
mkdir -p build
for total in 3 4; do
  for ((index=0; index<total; index++)); do
    flags=()
    if [[ "$total" == 3 ]]; then flags+=(--no-timings); fi
    rm -rf build/test_cache  # disposable compiler cache created by these runs
    shard_files="$(python3 tool/flutter_test_shards.py --total "$total" --index "$index" "${flags[@]}")"
    /usr/bin/time -p ./tool/flutterw test --reporter=json \
      --exclude-tags apple-mobile --no-pub --concurrency=4 $shard_files \
      > "build/shards-$total-$index.jsonl" 2> "build/shards-$total-$index.time"
  done
done
```

The complete maintained local equivalent of `.github/workflows/ci.yml` consists
of all four candidate shards plus the checks below. Python commands used
`--durations 0` only to expose timing; they execute the same unittest discovery
as CI. Chromium uses the checkout-local Chrome for Testing headless shell.
Android instrumentation is compiled, not executed on a device.

Every maintained local gate command exited 0. Each row was timed with
`/usr/bin/time -p`; timeout/environment wrappers are shown where used.

| Lane | Exact command | Result and command wall time |
| --- | --- | --- |
| Flutter shard 0 | `total=4`, `index=0` in the loop above | Exit 0; 419 passed, existing exclusions: 1; 24.90 s |
| Flutter shard 1 | `total=4`, `index=1` in the loop above | Exit 0; 368 passed, existing exclusions: 2; 48.90 s |
| Flutter shard 2 | `total=4`, `index=2` in the loop above | Exit 0; 351 passed, existing exclusions: 1; 24.85 s |
| Flutter shard 3 | `total=4`, `index=3` in the loop above | Exit 0; 499 passed, existing exclusions: 0; 19.43 s |
| Analyzer | `./tool/flutterw analyze --no-pub` | Exit 0; no issues; 12.98 s |
| Chromium | `env TMPDIR=build/t timeout --signal=INT --kill-after=10s 180s ./tool/flutterw test --no-pub --platform chrome --concurrency=1 --reporter=json test/local_review_quota_classifier_web_test.dart` | Exit 0; 4 passed; 68.01 s |
| tool/tests | `python3 -m unittest discover -s tool/tests -p 'test_*.py' --durations 0` | Exit 0; 213 tests; 1 existing exclusion; 28.30 s |
| tools/recall_sync/tests | `python3 -m unittest discover -s tools/recall_sync/tests -p 'test_*.py' --durations 0` | Exit 0; 63 tests; 8.24 s |
| tools/anki_revision/tests | `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py' --durations 0` | Exit 0; 63 tests; 5.30 s |
| tools/semantic_review/tests | `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py' --durations 0` | Exit 0; 36 tests; 0.86 s |
| tools/flag_report/tests | `python3 -m unittest discover -s tools/flag_report/tests -p 'test_*.py' --durations 0` | Exit 0; 13 tests; 0.10 s |
| tools/fsrs_optimize/tests | `python3 -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py' --durations 0` | Exit 0; 8 tests; 6.69 s |
| Android debug | `timeout --signal=TERM --kill-after=10s 900 ./tool/flutterw build apk --debug --no-pub` | Exit 0; APK compiled; 103.92 s |
| Release policy | `timeout --signal=TERM --kill-after=10s 1400 python3 tool/check_android_release_policy.py` | Exit 0; all 4 probes passed; 53.88 s |
| Android native | `timeout --signal=TERM --kill-after=10s 1800 ./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2` | Exit 0; 38 JVM tests, lint and instrumentation compilation passed; 189.76 s |

Sum of these successful command wall times: **596.12 s**. This is a
serial work total, excluding provisioning and profiling repeats. Hosted CI
runs its lanes in parallel; this total is not a measured hosted gate duration.
Raw disposable caches, logs, SDK copies and build artifacts were removed after
recording these results. No server, browser or Gradle daemon was retained.

## Remaining opportunities

Compilation/loading dominates the Flutter lane; individual test bodies are
usually much shorter. The existing instant-backoff fixture already preserves
all PostgREST retries without sleeping. Native release probes already reuse a
warm daemon only on disposable hosted runners. Neither needs a broader rewrite
for this change. Some Python suites also run through Dart wrapper tests; removing
that duplication would need a separate coverage/ownership decision.

A fourth runner increases SDK setup and aggregate runner work. This public
repository retains free hosted runners and its existing caches; there is no
self-hosted runner or paid-service change. Measure the next hosted run before
claiming a whole-gate throughput improvement or adding further shards.

# Sync and scheduling test hardening

Added 35 tests using invented scheduling rows, an in-memory replay gateway,
mock preferences, and a mocked Android method channel. No production behavior,
existing tests, card content, decks, articles, or database schema changed. No
real accounts, credentials, devices, backend services, or Apple mobile targets
were used. No production defect was reproduced.

## Selection and coverage

The baseline full Flutter suite passed 1,395 tests with 4 skipped. Flutter's
`--coverage` output identified the reminder controller/bridge (83.82%) as the
least-covered scheduling or sync module considered, followed by background
sync (88.24%), the widget bridge (89.36%), replay (90.48%), and the API (90.82%).
Local persistence was already at 98.28%, while the FSRS wrapper had 100% line
coverage. Auth storage and the browser platform stub were outside this
ticket's scheduling/sync scope. Native Kotlin and Python are not measured by
Flutter coverage.

| Exercised production module | Before | After |
| --- | --- | --- |
| `lib/features/review/application/fsrs_engine.dart` | 84/84 (100.00%) | 84/84 (100.00%) |
| `lib/features/review/data/review_replay.dart` | 38/42 (90.48%) | 39/42 (92.86%) |
| `lib/features/reminders/application/study_reminder_controller.dart` | 145/173 (83.82%) | 171/173 (98.84%) |

These are executed-line counts from `DA` records in `coverage/before.info` and
`coverage/after.info`, using the same full-suite command and pinned SDK. They
are not branch coverage. The remaining replay lines format an exception;
the remaining reminder lines reject invalid times and edits without an owner.
FSRS's unchanged percentage conceals additional boundary and state assertions.

## Protected behavior

- `test/fsrs_restoration_boundaries_test.dart`: persisted learning cards just
  below, exactly at, and above the final learning step; long imported gaps;
  absent/nonpositive stability; immutable fitted parameters; and replacing an
  applied fit with a suggestion without applying its parameters.
- `test/review_replay_boundaries_test.dart`: microsecond ordering, equivalent
  timezone offsets, malformed timestamps, explicit and legacy lapse flags,
  success on the fourth CAS attempt with freshly read counters, deletion or
  partial application during contention, and transport-error propagation.
- `test/study_reminder_android_bridge_test.dart`: permission results, exact
  native method/payload contracts, native errors and retry, cancellation without
  erasing the preference, midnight eligibility refresh, and cancelling the
  rearmed timer on sign-out. Platform overrides, timers and channel handlers
  are cleaned up by the tests.

## Validation

The SDK was copied from the installed Flutter 3.47.1 into the ignored
`build/toolchain/flutter-3.47.1` directory, as earlier repository validation
notes describe. `./tool/flutterw pub get --offline` passed without a lockfile
change. All generated files and mutable toolchain caches were repository-local.
Flutter commands used:

```sh
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export RECALL_FLUTTER_ROOT="$PWD/build/toolchain/flutter-3.47.1"
export DART="$RECALL_FLUTTER_ROOT/bin/dart"
export PATH="$RECALL_FLUTTER_ROOT/bin:$PATH"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/build/test-hardening/config"
export XDG_CACHE_HOME="$PWD/build/test-hardening/cache"
export TMPDIR="$PWD/build/test-hardening/tmp"
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=expanded --exclude-tags apple-mobile --concurrency=2 test/fsrs_restoration_boundaries_test.dart test/review_replay_boundaries_test.dart test/study_reminder_android_bridge_test.dart` | Exit 0; 35 passed. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile --concurrency=2 --coverage --coverage-path=coverage/before.info` | Exit 0; 1,395 passed, 4 skipped. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile --concurrency=2 --coverage --coverage-path=coverage/after.info` | Exit 0; 1,430 passed, 4 skipped. |
| `./tool/flutterw test --no-pub --platform chrome --concurrency=1 test/local_review_quota_classifier_web_test.dart` | Exit 0; 4 passed. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0; 175 tests, 1 skipped (retired Apple simulator helper). |
| `python3 -m unittest discover -s tools/recall_sync/tests -p 'test_*.py'` | Exit 0; 25 passed. |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | Exit 0; 29 passed. |
| `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | Exit 0; 35 passed. |
| `python3 -m unittest discover -s tools/flag_report/tests -p 'test_*.py'` | Exit 0; 11 passed. |
| `python3 -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py'` | Exit 0; 8 passed. |
| `./tool/flutterw build apk --debug --no-pub` | Exit 0; debug APK compiled. |
| `python3 tool/check_android_release_policy.py` | Exit 0; all four refusal/unsigned-staging probes passed. |
| `./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2` | Exit 0; 12 JVM tests passed, lint passed, instrumentation APK compiled; `BUILD SUCCESSFUL`. |

The browser command used a repository-local Chrome for Testing headless shell
via `CHROME_EXECUTABLE`. Python commands used a repository-local Python 3.12
virtual environment with the tools' dependencies, including CPU-only PyTorch;
hosted CI specifies Python 3.14/3.13. Thread pools were bounded to two workers
with `OMP_NUM_THREADS=2`, `MKL_NUM_THREADS=2`, `OPENBLAS_NUM_THREADS=2`, and
`NUMEXPR_NUM_THREADS=2`. The tooling suite also passed its 34,623-vector VM/JS
scheduler parity check. No iOS runner was imported or executed.

The maintained local equivalents of `.github/workflows/ci.yml` all passed.
Android SDK 37 was installed in the repository-local SDK copy; Gradle, Android,
Java and Kotlin state stayed local with:

```sh
export GRADLE_USER_HOME="$PWD/build/test-hardening/gradle"
export ANDROID_USER_HOME="$PWD/build/test-hardening/android"
export ANDROID_HOME="$PWD/build/toolchain/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export XDG_DATA_HOME="$PWD/build/test-hardening/data"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR -Duser.home=$PWD/build/test-hardening/java-home -XX:-UsePerfData"
export GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2 -Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process'
```

No hosted CI job was dispatched, and instrumentation tests were compiled rather
than executed on a device. Disposable SDKs, dependency caches, generated builds,
and raw coverage files were removed after validation; the coverage counts and
exact commands are retained here.

## Remaining scope

The reminder bridge tests assert Dart-to-Android dispatch; they do not execute
Android alarms or prove notification delivery after reboot or process death.
The replay tests exercise the documented client fallback, not the transactional
PostgreSQL RPC or deployed RLS. The README's known fallback idempotency and undo
concurrency limits remain. Importer behavior, persistence migration scenarios,
and widget lifecycle gaps were left to their existing suites to keep this
change focused. No live-data or device acceptance is claimed.

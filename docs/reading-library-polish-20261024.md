# Reading and library polish — 2026-10-24

README.md and docs/testing.md were read first; this checkout has no AGENTS.md.
All changes, disposable toolchains, caches and captures stay in this checkout.
Git metadata is read only; the runner owns the commit. No existing tests or
baselines were edited. StudyScreen and ReviewController are unchanged. All
exercised content is synthetic; no live account, personal content or test network
service was used. No Apple mobile build or test was run.

## Changes

Five focused presentation fixes, covered by eight new widget cases in
`test/reading_library_polish_test.dart`:

- Library search can clear whitespace and returns typing focus after either
  pointer or keyboard activation of Clear search.
- Inline primers remember their individual scroll offsets when reopened;
  another primer starts at its own position.
- Reading retains its search query through a failed refresh and retry. Results
  and the recent-reading section agree with the restored query.
- The reading-pane header wraps at narrow widths with large text instead of
  overflowing beside the Back button.
- Settings' Set override and Use default controls announce the relevant deck,
  so repeated controls are distinguishable with assistive technology.

The same fixtures cover dark surfaces, long titles, no search results,
loading/empty/error states and keyboard traversal/activation at 320px and 1280px.
The API, preferences and review-controller doubles fail on unexpected access.
The store double returns an empty remediation queue from memory.

## Acceptance boundaries

Synthetic captures are in ignored `build/reading-library-polish/`. The temporary
capture driver loads bundled fonts and runs only its own file with
`--update-goldens`; it never regenerates existing baselines. Phone and desktop
captures include Reading, Library, primers, Settings, expanded deck overrides,
loading, errors and empty results. Captures were visually inspected, including
320px at double text size and a 280px inline reading pane.

Native widget rendering uses Flutter's Android test target; this is not an
installed app or Android emulator acceptance claim. Chromium executes the
presentation regressions against local fixtures. README.md retires this
checkout's PWA from building/publishing: Recall Hub is a separate repository and
was not accessed or changed.

The concept-library model has no like/dislike field or mapping from card-level
flags to primer rows. No indicator semantics were invented. Card flag behavior
remains covered by the unchanged full suite; adding indicators to these lists
needs a separately defined product/data contract.

## Verification

Flutter 3.47.1 and the package cache were copied into ignored `.tools/`.
Dependencies resolved offline with the lockfile enforced. Android SDK 37.0,
Gradle inputs, Python dependencies and temporary files also stayed here.
The installed JDK and Chromium binaries were used read only. Robolectric's
framework fixtures were copied and its runtime resolver was configured offline.

Final local commands and results (exit 0 unless explicitly noted):

| Exact command | Result |
| --- | --- |
| `./tool/flutterw pub get --offline --enforce-lockfile` | Passed; lockfile unchanged. |
| `./tool/flutterw analyze --no-pub` | No issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --concurrency=2 --exclude-tags apple-mobile` | 1,625 passed; 4 skipped. Existing golden comparisons matched. |
| `timeout --signal=INT --kill-after=15s 600s ./tool/flutterw test --no-pub --platform chrome --concurrency=1 --reporter=expanded test/reading_library_polish_test.dart test/local_review_quota_classifier_web_test.dart` | 12 passed in Chromium: 8 new presentation regressions and 4 required browser cases. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | 201 run; 1 skipped. |
| `python3 -m unittest discover -s tools/recall_sync/tests -p 'test_*.py'` | 63 passed. |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | 63 passed. |
| `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | 36 passed. |
| `python3 -m unittest discover -s tools/flag_report/tests -p 'test_*.py'` | 13 passed. |
| `python3 -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py'` | 8 passed, CPU PyTorch with two OpenMP/MKL threads. |

Python commands used the checkout-local virtual environment, with `DART` and
`PATH` pointing at the copied pinned SDK. The first tooling run selected the
older global Dart and failed its scheduler compile; the corrected run above
passed without changing tests. Initial build attempts encountered copied-cache
permissions; initial browser attempts encountered Chromium's socket path limit
and an outer timeout. The final browser launcher uses a relative temporary path
inside ignored build output. These setup fixes did not alter production code,
existing tests or test timeouts.

| Exact Android command | Result |
| --- | --- |
| `./tool/flutterw build apk --debug --no-pub` | Passed; debug APK compiled without runtime configuration or installation. |
| `android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process` | BUILD SUCCESSFUL; 38 JVM tests, zero failures/errors/skips; lint passed; instrumentation APK compiled, not executed. |
| `python3 tool/check_android_release_policy.py` | All four refusal/unsigned-staging probes passed. |
| `android/gradlew -p android --stop` | Exit 0; no Gradle daemons running. |
| `git diff --check` | No whitespace errors. |

The capture-only command was `./tool/flutterw test --no-pub --reporter=failures-only --update-goldens .tools/reading_capture_test.dart`: 10 cases passed and 23 synthetic PNGs were written under ignored build output. Its driver is retained beside the captures as `capture_test.dart`.

The maintained CI equivalent is green locally. No hosted CI run, device runtime
acceptance or production delivery is claimed.

## STATUS: Ready for German

Automatic command review rejected the bundled disposable-output cleanup before
execution: `rm -rf .tools .dart_tool android/.gradle android/.kotlin android/app/.cxx`,
`rm -f .flutter-plugins-dependencies android/local.properties`, and the following
Python cleanup of generated build output. The stated reason was:
“rm -f style commands are not permitted. Use a safer approach”. The rejected
cleanup was not retried. Copied toolchains remain in ignored `.tools/`, and
generated build outputs remain in ignored paths. No Gradle daemon is running.

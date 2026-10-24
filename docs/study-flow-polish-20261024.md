# Study-flow polish — 2026-10-24

README.md and docs/testing.md were read first; no repository AGENTS.md exists.
All edits and toolchain/cache writes stayed in this checkout. Git metadata was
read only; the runner owns the commit. No existing tests or golden baselines
were changed. All exercised cards, reading, preferences and transports were
synthetic; no live account, content, credentials or external test service was
used. No Apple mobile build or device test was run.

## Changes

- On the focused Study surface, Space reveals the answer; a second press saves
  Good. The next card stays on its question. Focused buttons retain normal Space
  activation, and a reading input keeps its keys until Study is clicked again.
- Ctrl/Alt/Meta/Shift combinations no longer reveal or rate cards. Held review
  keys are consumed without repeating the action or passing Space to scrolling.
- Completion retains the durable daily total and transient flag confirmation,
  including the last-card dislike message. The confirmation remains an accessible
  live region; its expiry leaves the count visible. The existing count ownership,
  scheduler, persistence and Undo rules are unchanged.

The production patch only changes StudyScreen. The eleven added cases in
`test/study_flow_polish_test.dart` cover these behaviors, local Undo/counts,
Like/unlike activation and 320px completion at normal and 2× text size.

## Acceptance and limits

The full Flutter suite renders Study, Reading, Library and Settings with test
fixtures, including the existing 51 reading/settings/stats golden comparisons at
360px, 412px and 1280px. Representative existing 412px Reading, Library and Settings
baselines were visually inspected. No new screenshots were saved: the requested
`~/Code/_runs/visual-20261024/recall-b/` destination is outside the permitted
checkout. No existing baselines were regenerated.

The maintained web client is Recall Hub in a separate repository; README.md
retires this checkout's Flutter PWA from building and publishing. Browser widget
checks here do not establish Recall Hub acceptance. No app was installed, no
emulator was started and no production delivery was attempted.

Follow-up: the existing completion Undo label still says “Undo last rating”
after hiding a card. Its existing acceptance tests pin that label; changing
the hide-specific wording is left for a separate UI contract update.

## Verification

Flutter 3.47.1 and the package cache were copied into ignored checkout-local
directories; `./tool/flutterw pub get --offline --enforce-lockfile` passed without
changing pubspec.lock. Temporary Python dependencies, Android SDK 37.0, Gradle
caches, configuration and temporary files also stayed in this checkout. The
installed JDK 17 and Chrome executables were used read only. Robolectric uses
copied framework fixtures with its runtime dependency resolver offline.

The first full Flutter run had one failure: the existing semantic-review Python
wrapper exceeded its 30-second timeout. Its direct Python suite passed. The
final full run uses the documented two-worker limit without modifying tests or
timeouts.

Final maintained local gate results (exit 0 for every row):

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/study_flow_polish_test.dart` | 11 passed. |
| `./tool/flutterw analyze --no-pub` | No issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --concurrency=2 --exclude-tags apple-mobile` | 1,617 passed; 4 skipped. All 51 existing goldens matched. |
| `timeout --signal=INT --kill-after=15s 120s env TMPDIR="$PWD/build/tq" ./tool/flutterw test --no-pub --platform chrome --concurrency=1 --reporter=expanded --exclude-tags apple-mobile test/local_review_quota_classifier_web_test.dart` | 4 passed in Chromium. |
| `./tool/flutterw build apk --debug --no-pub` | Debug APK compiled. No runtime configuration or installation. |
| `android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process` | BUILD SUCCESSFUL; 38 JVM tests, zero failures/errors/skips; lint passed; instrumentation APK compiled, not executed. |
| `python3 tool/check_android_release_policy.py` | All four signing-refusal/unsigned-staging probes passed. |
| `.tools/polish-runtime/venv/bin/python -m unittest discover -s tool/tests -p 'test_*.py'` | 201 run, 1 skipped. |
| `.tools/polish-runtime/venv/bin/python -m unittest discover -s tools/recall_sync/tests -p 'test_*.py'` | 63 passed. |
| `.tools/polish-runtime/venv/bin/python -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | 63 passed. |
| `.tools/polish-runtime/venv/bin/python -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | 36 passed. |
| `.tools/polish-runtime/venv/bin/python -m unittest discover -s tools/flag_report/tests -p 'test_*.py'` | 13 passed. |
| `.tools/polish-runtime/venv/bin/python -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py'` | 8 passed, with CPU PyTorch and two OpenMP/MKL threads. |
| `git diff --check` | No whitespace errors. |

An extra attempt to run the new native-storage widget fixtures in Chromium did
not complete the first case:

```sh
timeout --signal=INT --kill-after=15s 180s env TMPDIR="$PWD/build/tp" \
  ./tool/flutterw test --no-pub --platform chrome --concurrency=1 \
  --reporter=expanded --exclude-tags apple-mobile test/study_flow_polish_test.dart
```

Exit 124 (the outer timeout); no passing browser study-flow result is claimed.
The production store uses browser Web Locks, while these widget fixtures run
under fake async. This attempt does not isolate the cause of the stall. The
required browser quota suite passed separately, and the native widget fixtures
pass in the complete default Flutter suite. No existing tests, timeouts or
browser locking behavior were changed to make acceptance pass.

The isolated Gradle stop command, `android/gradlew -p android --stop`, exited 0
and reported no running daemons. Disposable task toolchains/caches and generated
build outputs were removed after verification; no preview or emulator remains.

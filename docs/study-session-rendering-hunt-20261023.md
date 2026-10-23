# Android study-session rendering hunt — 2026-10-23

Read README.md, docs/testing.md, ANDROID_SETUP.md and every existing hunt note.
No repository AGENTS.md exists. Baseline HEAD and local main are both
`0d3876135bd7da5cab7702db23dea626ad927cb9`. Git metadata was read only; the
runner owns the commit. No existing tests, controller, decks, offline-count,
reminder, dependency, platform or backend source was changed. Tests use invented
fields, fake transports and isolated browser/preferences fixtures only.

## Three fixes

All production changes are in
`lib/features/review/presentation/widgets/card_face.dart`.

1. **Line breaking changed the formula's meaning.** The source-level splitter
   recognized binary operators by prefix. `a\cdots z` became `a\cdot s z`,
   displaying a multiplication dot and an extra letter instead of an ellipsis.
   `x\pmod{n}` became plus/minus followed by `od`. Require a complete TeX control
   word before inserting a breakpoint. Existing narrow formula wrapping remains
   covered by the unchanged CardFace tests.
2. **Invisible delimiters became visible dots.** Removing only `\left` and
   `\right` left the dot in one-sided evaluation notation such as
   `\left.x\right|`. Remove the invisible dot with its sizing command, including
   an intervening space. Visible delimiters and arrow commands retain their
   existing behavior.
3. **Cloze hints displayed markup instead of the hint.** Hints used plain Text,
   so `<b>A &amp; B</b> \(x^2\)` displayed tags, entities and raw TeX. Render hints
   through the existing HTML/math pipeline, retaining brackets and the pill's
   accent color. Reveal still replaces the hint with the answer on the same
   mounted, cached face.

`test/study_math_cloze_regression_test.dart` adds eight cases. Math checks
compare the actual rendered syntax trees with the package's unsplit TeX trees;
merely checking parse success would miss the valid-but-wrong dot-plus-s formula.
The hint test checks hidden answer content, decoded/styled text, rendered math,
accent color and reveal. Seven cases fail against original source; the complete
operator-name control already passes. All eight pass with the fixes.

## Deferred finding and coverage limits

The existing brace-balancing cloze parser treats TeX's escaped `\{` as an open
content group. For example, `{{c1::\(\{x\)::opening brace}}` renders literally,
exposing its answer before reveal. A broad escape-rule change also affects
literal backslashes before closing cloze braces in code/path fields. The parser
is unchanged pending a separately scoped grammar decision and compatibility
tests; the exploratory parser changes/tests were removed from this patch.

Scheduling fuzz and learning-step restoration, pause/reconstruction and Undo,
session summary counts, and synthetic scale flows remain covered by the existing
full suite and the tool suite's 34,623 VM/JavaScript scheduler vectors. No new
defect in those areas was established beyond earlier hunt findings. The held
PR files were left untouched. There was no physical Android process-kill test,
large-deck device profile, or live Recall Hub visual comparison. The math proof
here is against the installed renderer's TeX semantics.

## Validation

Flutter 3.47.1 was bootstrapped into the ignored `build/toolchain/` directory;
dependencies resolved without a tracked lockfile change. Android SDK/cache and
Python virtualenv changes also stayed inside this checkout. Commands used:

```sh
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
export RECALL_FLUTTER_CACHE_ROOT="$PWD/build/toolchain"
export RECALL_FLUTTER_ROOT="$PWD/build/toolchain/flutter-3.47.1"
export DART="$RECALL_FLUTTER_ROOT/bin/dart"
export PATH="$RECALL_FLUTTER_ROOT/bin:$PATH"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/build/tool-config"
export XDG_CACHE_HOME="$PWD/build/tool-cache"
export TMPDIR="$PWD/build/tool-tmp"
export GRADLE_USER_HOME="$PWD/build/gradle-home"
export JAVA_HOME=/home/ger/.local/share/fleet-toolchains/temurin-17
export ANDROID_HOME="$PWD/build/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$PWD/build/android-home"
```

The maintained test/check commands from README, testing.md and CI were run;
Apple mobile tests were excluded. No device installation or signed delivery was
attempted.

| Exact command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/study_math_cloze_regression_test.dart` against original source, restored afterward | Exit 1; 7 failed, 1 passed. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/study_math_cloze_regression_test.dart test/card_face_test.dart test/cloze_test.dart` | Exit 0; 69 passed. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0; 1,454 passed, 4 skipped. |
| `cd android && ./gradlew --no-daemon :app:testDebugUnitTest :app:lintDebug` | Exit 0; 12 unit tests, zero failures/errors/skips; lint passed. |
| `./tool/flutterw build apk --debug --no-pub` | Exit 0; debug APK compiled without runtime configuration. No installation. |
| `cd android && ./gradlew --no-daemon --max-workers=2 :app:assembleDebugAndroidTest` | Exit 0; instrumentation APK compiled. No emulator/device tests executed. |
| `python3 tool/check_android_release_policy.py` | Exit 0; all four signed-release refusal/unsigned-staging probes passed. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0; 178 run, 1 skipped. |
| `python3 -m unittest discover -s tool/tests -p 'test_benchmark_source_pins.py'` | Exit 0; both passed before changes. HEAD equals local main and all pinned inputs are unchanged, so the reported two failures do not reproduce on local main. No pin refresh needed. |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | Exit 0; 29 passed. |
| `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | Exit 0; 35 passed. |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | Exit 0; 30 passed. |
| `build/test-venv/bin/python -m unittest discover -s tools/recall_sync/tests` | Exit 0; 25 passed. |
| `build/test-venv/bin/python -m unittest discover -s tools/flag_report/tests -p 'test_*.py'` | Exit 0; 11 passed. |
| `build/test-venv/bin/python -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py'` with `OMP_NUM_THREADS=2 MKL_NUM_THREADS=2` | Exit 0; 8 passed. |
| `TMPDIR="$PWD/build/t" CHROME_EXECUTABLE=/home/ger/.local/share/fleet-toolchains/hq-surf-chrome-154.0.8037.92/chrome-linux64/chrome ./tool/flutterw test --no-pub --platform chrome --concurrency=1 --exclude-tags apple-mobile test/local_review_quota_classifier_web_test.dart` | Exit 0; 4 passed. |
| `git diff --check` | Exit 0. |

An initial tool-suite run used the old global Dart and exited 1; setting DART to
the pinned local executable fixed that environment error. The first browser
attempt exited 1 because its Unix socket path exceeded the platform limit;
shortening TMPDIR within this checkout fixed it. The first Android compile could
not write a Kotlin daemon marker outside the checkout and successfully used the
compiler's in-process fallback. No source workaround or test weakening was used.

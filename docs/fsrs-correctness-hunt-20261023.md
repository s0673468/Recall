# FSRS correctness hunt — 2026-10-23

Recall's engine comment claims FSRS-6. The compatibility reference is
[the optimizer contract](../tools/fsrs_optimize/README.md): official Python
`fsrs` **6.1.1**, with 21 parameters matching Dart `fsrs` **2.0.1** in
`pubspec.lock`. All observations below use invented scheduling fields. No
personal cards, content, credentials, live backend or device were accessed.
There is no checkout `AGENTS.md`; README and the supplied instructions were
read first. Git metadata and the files reserved for PRs #175/#176 were not
changed. Existing tests were not edited.

## Four fixes

1. **Half-day ties differed from the reference.** Python's `_next_interval`
   rounds to the nearest even day; Dart's `round()` rounds positive ties up.
   A valid synthetic fit with initial Easy stability 2.5 scheduled **3 days**
   in Recall versus **2 days** in Python; 4.5 scheduled **5 versus 4**.
   The wrapper now applies the reference rounding to review-state results in
   the shared preview/rating path. The one-day minimum and 36,500-day maximum
   still apply. Learning and relearning delays still come from the package.
2. **Invalid retention reached interval arithmetic.** Nonfinite values and
   values outside the open interval `(0, 1)` were accepted by the engine and
   stored-settings parser. Depending on the rating, they produced an invalid
   interval, a misleading minimum interval or a delayed arithmetic failure.
   Parsing now refuses these settings; direct engine changes reject them
   before changing the applied configuration. The optimizer's existing,
   narrower 0.70–0.97 product range remains intact.
3. **Rejected weights left a partially replaced engine.** `_configure` assigned
   weights and retention before constructing the validating scheduler. An
   invalid fit therefore left old scheduling paired with new getters/clamp
   weights, and the next retention edit failed using those rejected weights.
   Configuration now validates a complete candidate before replacing fields.
   The regression also preserves the applied status and fitted timestamp.
4. **Optimizer apply accepted unusable finite weights.**
   `FsrsOptimizerResult.tryParse` checked length and finiteness but omitted
   the package bounds, allowing the guarded API to persist a vector that the
   scheduler subsequently rejected. It now checks each of the 21 official
   bounds before any transport. Tests preserve acceptance of every exact
   lower/upper bound and reject synthetic out-of-range reports without a
   request. Stored settings also reject nonfinite weights.

## Reference logs and retained behavior

[The new regression suite](../test/fsrs_correctness_hunt_test.dart) replays
[fixed synthetic reference logs](../test/support/fsrs6_synthetic_logs.dart).
Expected values were generated independently with official Python `fsrs==6.1.1`
using `Scheduler(parameters=..., desired_retention=..., enable_fuzzing=False)`
and sequential `review_card(..., review_datetime=...)` calls. Each event pins
its interval in seconds, stability, difficulty and state. The Dart test
serializes/reconstructs the card after every event and compares the actual
rating with its preview. The fixtures contain only identifiers, scheduler
parameters, scheduling states, ratings and timestamps.

The learning/relearning log's intervals are **10 min, 10 min, 2 d, 8 d, 11 d,
10 min, 15 min, 10 min, 1 d, 7 d**. Further logs cover imported mature history
with synthetic fitted weights at retention 0.70/0.90/0.97, early and late
reviews, the maximum interval, the one-day minimum and values immediately
below/at/above a half-day boundary.

The engine's documented disabled fuzz and legacy learning-stability clamp
remain intentional differences from an unwrapped reference scheduler. Existing
step reconstruction, lapse bookkeeping, replay/undo protection and queue day
boundaries were retained and exercised by the existing tests. Remote undo
still fails closed; no concurrent server-undo contract is introduced. The
new logs do not claim to replace Anki's configurable learning-step schema.

The logs start at 00:05 São Paulo / 03:05 UTC. Explicit offset/local timestamps
are checked against the same UTC due instant. Existing date/queue tests also
ran under UTC, São Paulo and New York; their synthetic timezone injection
covers 23-hour and 25-hour Berlin days.

## Validation environment

All SDKs, package caches, temporary files and the Python virtualenv stayed
inside this checkout's ignored build/cache directories. Flutter 3.47.1 was
prepared by `tool/bootstrap_flutter`; `./tool/flutterw pub get` exited **0**
without a lockfile change. The Python environment installed the repository's
requirements, official `fsrs==6.1.1`, and CPU-only Torch. Tests used these
exports (the temporary `build/fsrs-env.sh` contained the same exports):

```sh
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export RECALL_FLUTTER_ROOT="$PWD/build/flutter-cache/flutter-3.47.1"
export RECALL_FLUTTER_CACHE_ROOT="$PWD/build/flutter-cache"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/build/xdg-config"
export XDG_CACHE_HOME="$PWD/build/tool-cache"
export TMPDIR="$PWD/build/tool-tmp"
export PATH="$PWD/build/reference/venv/bin:$RECALL_FLUTTER_ROOT/bin:$PATH"
export OMP_NUM_THREADS=2 MKL_NUM_THREADS=2
mkdir -p "$TMPDIR"
```

## Commands and results

The first regression run, before implementation, was:

```sh
./tool/flutterw test --no-pub --reporter=expanded test/fsrs_correctness_hunt_test.dart
```

**Exit 1:** 8 passed, 12 failed, exposing all four findings. Four additional
boundary/validation cases were subsequently added; the final new suite has
24 tests.

The review-feature command was:

```sh
TZ=America/Sao_Paulo ./tool/flutterw test --no-pub --reporter=expanded --concurrency=2 test/fsrs_correctness_hunt_test.dart test/recall_fsrs_test.dart test/fsrs_restoration_boundaries_test.dart test/review_date_boundaries_test.dart test/review_replay_boundaries_test.dart test/review_scheduling_mutation_test.dart test/fsrs_optimizer_test.dart test/scheduler_protocol_test.dart
```

**Exit 0: 132 passed.** Each of the following also exited **0: 81 passed**:

```sh
TZ=UTC ./tool/flutterw test --no-pub --reporter=expanded --concurrency=2 test/fsrs_correctness_hunt_test.dart test/review_date_boundaries_test.dart test/recall_api_introduction_dst_day_test.dart
TZ=America/New_York ./tool/flutterw test --no-pub --reporter=expanded --concurrency=2 test/fsrs_correctness_hunt_test.dart test/review_date_boundaries_test.dart test/recall_api_introduction_dst_day_test.dart
```

Maintained Python suites and benchmark/source guards:

| Exact command | Result |
| --- | --- |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0; 183 run, 1 retired Apple test skipped. |
| `PYTHONPATH=. python3 -B test/test_synthetic_native_prepare.py` | Exit 0; 2 passed. |
| `python3 -m unittest discover -s tools/recall_sync/tests` | Exit 0; 25 passed. |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | Exit 0; 29 passed. |
| `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | Exit 0; 35 passed. |
| `python3 -m unittest discover -s tools/flag_report/tests -p 'test_*.py'` | Exit 0; 11 passed. |
| `python3 -m unittest discover -s tools/fsrs_optimize/tests -p 'test_*.py'` | Exit 0; 8 passed. |
| `python3 -m unittest discover -s web/tool/tests -p 'test_*.py'` | Exit 0; 11 passed. |

An initial tooling run exited **1** because formatting displaced mutation
anchors S18/S19. Keeping the scheduler call in its existing multiline form
restored both exact anchors; no test or mutation contract was weakened. The
final source-pin checks passed, so no benchmark re-pin was necessary.

The README's full portable Dart gate and the final affected-file command are
recorded below. There is no `make check` target in this checkout. Native Android
build/lint/device checks and the browser-only Chrome quota test were not run;
no native or browser implementation changed. No iOS build or test was run.
These results establish synthetic scheduling and regression coverage, not a
deployment or device result.

| Exact final command | Result |
| --- | --- |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues. |
| `TZ=America/Sao_Paulo ./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile --concurrency=2` | Exit 0; 1,492 passed, 4 skipped. |
| `python3 tool/affected_tests.py --base HEAD --path lib/features/review/application/fsrs_engine.dart --path lib/features/review/data/models.dart --run --concurrency 2` | Exit 0; analyzer passed; 1,241 tests passed, 3 skipped; no native lane selected. |
| `git diff --check` | Exit 0. |

The earlier `python3 tool/affected_tests.py --base HEAD --run --concurrency 2`
also exited **0** with the same 1,241 passing tests and 3 skips. HEAD is the
checkout's unchanged starting commit; all task changes were unstaged because
the runner owns committing. No push, PR, remote change or commit was attempted.

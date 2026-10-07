# Shared scheduler: synthetic proof and JavaScript build

This bridge compiles Recall's **existing** `FsrsEngine`, its plain data models,
 and the locked `fsrs` 2.0.1 package. It contains no copied FSRS formulae and makes
no changes to phone behavior, production data, schema or FSRS settings.

Use the repository-pinned Flutter SDK and its sibling `dart` executable:

```sh
./tool/flutterw pub get
DART=/path/to/pinned/flutter/bin/dart node tool/scheduler/build.mjs
node tool/scheduler/differential.mjs build/scheduler
./tool/flutterw test test/scheduler_protocol_test.dart
```

The generator runs 3,072 deterministic, invented histories through the real
Dart VM engine, producing over 30,000 outcomes. It covers all four states and
ratings, due-gap learning-step reconstruction at either side of ten minutes,
inflated learning stability, relearning step zero, missing durable fields,
same-day and delayed reviews, leap dates, year boundaries, applied and suggested
optimizer settings, varied retention, custom 21-weight parameter vectors, and
microsecond timestamps. The generator and verifier require every state and rating
to occur in the random histories themselves, including actual lapse transitions.

The same wire protocol is compiled with `dart compile js -O2`. `engine.mjs` is a
95 KB ES module that exports `schedule(request)` and runs in browser, Node and
Worker environments with no DOM requirement, eval, WebAssembly loader or Flutter
renderer. It exports via `dart:js_interop`; the wrapper immediately removes its
transient global export. Inputs support `review`, `preview`, `retrievability` and
`batch`; reviews take a rating 1–4 and an explicit ISO timestamp. The card uses
Supabase fields; `lastReview` is also accepted as an alias of `last_review`.

The verifier compares every output against the VM vectors: timestamps and all
non-numeric fields exactly, every float with absolute tolerance 1e-9. Strict mode
refuses an artifact unless it matches 100%. For an explicitly accepted read and
preview fallback, append `--allow-unverified` to both commands. This retains the
full corpus and tolerance, writes `verified:false` plus exact mismatch counts,
maximum float error and due-date counts, and requires grading to stay disabled.
The source/compiler/asset hashes bind either report to the actual engine.
Consumers must rerun the verifier at their build gate, use the same engine asset,
and disable grading when the proof is false, missing, incomplete or stale.

Dart JS and WASM were both evaluated. The native VM computes
`exp(0.017157218632938013)` as `1.0173052490937204`; V8 rounds to its upper
neighbor. FSRS subtracts one, amplifying the one-ULP difference into 2.15e-9
stability for an extreme synthetic history. A 100-digit independent oracle
confirms the native result is correctly rounded.

The compiled module now uses a **module-local** numerical adapter over the
conventional small positive exponential range `[0, ln(2)/2]`. Error-free TwoSum
and split-product transforms keep double-double intermediates in the positive
Taylor series before the final binary64 result. This also avoids double rounding
from a plain `1 + expm1(x)`. Outside that range the original Math backend is used;
global Math, native Dart, FSRS formulas, package versions and the native corpus
are unchanged. The proof binds the adapter's source hash as well as the compiled
Dart source and complete engine bytes.

All 34,623 original native vectors now pass at the unchanged 1e-9 tolerance,
with 34,879 exact due comparisons. `numeric_math.test.mjs` independently checks
529 100-digit oracle cases, including the failing argument and its adjacent
binary64 values, tiny arguments and the range boundary. Regenerate that synthetic
oracle with `python3 tool/scheduler/generate_numeric_oracle.py`.

 Golden fixtures
belong in tests and must never be downloaded in normal app use. Generated output
is ignored build data, rather than committed source in this public repository.

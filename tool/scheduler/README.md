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

Dart JS and WASM were both evaluated. With complete random histories, one extreme
stability of about 452,207 days differs by roughly 2.15e-9 between the M1 native
VM and web math; all 34,879 compared due dates remain exact. Neither web target
currently meets the strict grading threshold across the full corpus. The fallback
can show interval previews, but must not schedule or enqueue graded reviews. Golden fixtures
belong in tests and must never be downloaded in normal app use. Generated output
is ignored build data, rather than committed source in this public repository.

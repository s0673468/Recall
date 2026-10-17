# Local test feedback

Use the smallest relevant checks while editing, then the existing complete CI on
the final commit. Recall is public; its hosted required checks do not use private
Actions minutes. A local subset is never a substitute for those checks.

Prepare the pinned SDK with `./tool/bootstrap_flutter` and resolve dependencies
with `./tool/flutterw pub get`. Reuse the SDK and package/build caches; do not run
`flutter clean` between ordinary edits. Install each Python tool's requirements
in an isolated environment when working on that tool.

```sh
# Plan only. Includes branch changes since merge-base, staged, unstaged and
# untracked files; both paths of renames/deletions are considered.
python3 tool/affected_tests.py --base origin/main

# Run portable checks on ger-z. The default is two Flutter workers; choose a
# concurrency no larger than the fleet reservation.
python3 tool/affected_tests.py --base origin/main --run --concurrency 2

# Include an extra dependency when a change has a relationship beyond imports.
python3 tool/affected_tests.py --base origin/main --path lib/features/review/data/recall_api.dart

# Run selected native Android checks, after pub get.
python3 tool/affected_tests.py --base origin/main --lane android --run
```

Recall's application platforms are Android and web. There is no iOS lane:
iOS is not maintained, and its preserved tests are tagged `apple-mobile` and
skipped.

Dart selection follows transitive imports, exports and parts, including
conditional platform imports. File-based Dart contract tests run alongside each
Dart subset. A new module with no test consumer runs the full Flutter suite.
Python tool changes select their owning suite without starting Flutter. Native
changes select that native lane plus all Flutter contracts. Unknown paths,
dependency/configuration changes, selector changes or an unavailable Git base
select all lanes. Plans list deferred native lanes explicitly.

The analyzer remains broad because type errors can cross a test boundary. The
selector is a feedback aid, not a proof of exhaustive dependencies: runtime data,
reflection and semantic relationships still need the full final CI. Each executed
command prints its wall time and exit status. Narrow runs do not create reusable
passing-gate receipts. Combined plans avoid repeating the three Python suites
already executed by Dart wrapper tests.

## Suite speed

Hosted CI splits the Flutter tests into whole-file shards with
`tool/flutter_test_shards.py` and runs each at `--concurrency=4`, the hosted
runner's vCPU count. Built-in `--total-shards` is avoided because it slices the
tests inside every file, so each shard would still compile the whole suite.
The required `flutter` check passes only when `flutter-checks` (analyze, browser
and tooling tests) and every `flutter-tests` shard succeeded.

Tests that drive a 503 or an offline transport through postgrest wrap the call
in `withInstantRetryBackoff` (`test/support/instant_retry_backoff.dart`). Every
retry still runs; only the real 1 s + 2 s + 4 s backoff sleep is skipped.

## Coverage boundaries

- Flutter tests exercise scheduling, replay/idempotency, auth, owner isolation,
  offline state and synthetic UI flows. Mock HTTP tests do not execute PostgreSQL
  RPCs or prove production row-level security. Schema/RPC checks have their own
  documented local/production authority in `scripts/supabase/README.md`.
- Android unit/lint and `assembleDebugAndroidTest` check code and compilation.
  Building the instrumentation APK does **not** execute its device tests.
- Keep Android native behavior checks when changing Kotlin bridges, widgets or
  persistence. iOS XCTest and the simulator helper are not maintained
  (Android + web only); the CI `ios-native` context is retired and kept only as
  a check name.
- Python tools have direct suites in `tools/*/tests`, `tool/tests`, `scripts/tests`
  and `web/tool/tests`. The broad Flutter suite alone is not the whole CI gate.

For a failing behavior, add a regression that fails before the fix, run that
test while iterating, then use the affected plan. Required CI runs all maintained
lanes once on the final head; a changed head invalidates its earlier receipt.

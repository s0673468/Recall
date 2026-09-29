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

# Run selected native checks on the matching host, after pub get.
python3 tool/affected_tests.py --base origin/main --lane android --run
python3 tool/affected_tests.py --base origin/main --lane ios --run
```

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

## Coverage boundaries

- Flutter tests exercise scheduling, replay/idempotency, auth, owner isolation,
  offline state and synthetic UI flows. Mock HTTP tests do not execute PostgreSQL
  RPCs or prove production row-level security. Schema/RPC checks have their own
  documented local/production authority in `scripts/supabase/README.md`.
- Android unit/lint and `assembleDebugAndroidTest` check code and compilation.
  Building the instrumentation APK does **not** execute its device tests.
- iOS XCTest uses the disposable simulator helper. Keep native behavior checks
  when changing Swift/Kotlin bridges, entitlements, widgets or persistence.
- Python tools have direct suites in `tools/*/tests`, `tool/tests`, `scripts/tests`
  and `web/tool/tests`. The broad Flutter suite alone is not the whole CI gate.

For a failing behavior, add a regression that fails before the fix, run that
test while iterating, then use the affected plan. Required CI runs all maintained
lanes once on the final head; a changed head invalidates its earlier receipt.

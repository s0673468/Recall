# Offline deck counts and stale Android reminders — 2026-10-23

The ticket's two follow-ups are implemented. No existing tests were edited or
deleted. Git metadata/remotes were not changed; the runner owns the commit.

## Behavior

- Decks retains the last successful, account-scoped server aggregates in a
  disposable cache. Each offline read overlays the current durable review
  outbox, subtracting each distinct card once from its original due/new bucket.
  Reviews now carry local-only deck, previous-state and previous-due metadata,
  so queue pruning and a restart do not lose the bucket information. Replay's
  explicit server fields remain unchanged. Future-due validation/ahead cards
  do not subtract from an earlier server due bucket; counts cannot go negative.
- Ratings and undo refresh the visible counts while offline. Manual refresh,
  refreshed deck lists, and outbox drains try the server again, including drains
  that precede clearing Study's offline flag. Successful server reads replace
  the cached baseline; network failures fall back to the cache. Overlapping or
  owner-expired requests cannot publish/cache an older response. Sign-out's
  existing cache clear also removes the new count snapshot.
- Android cancellation withdraws only Recall's study reminder notification as
  well as clearing the alarm and eligibility. Disabled reminders, zero due work,
  studying today, explicit cancellation and owner release share this path.
  Eligible refreshes retain a displayed reminder. The notification identifier
  is shared between posting and dismissal.

`test/offline_deck_counts_test.dart` adds synthetic unit/widget coverage for
restart, due/new buckets, deduplication, future-due cards, absent decks, bounds,
legacy entries, undo, server convergence/reconnect, account isolation, cache
clear, unreadable cache, response ordering and production review-entry metadata.
`RecallReminderDismissalTest.kt` adds five native cases, each executed on APIs
28 and 35, including consumed eligibility and preservation of unrelated posted
notifications. No live backend, credentials, personal data, messages, emulator,
physical device or Apple mobile target was used.

## Validation environment

The pinned Flutter 3.47.1 SDK and package, Gradle, Android SDK and Robolectric
framework caches were copied into ignored checkout-local directories. API 37.0
was installed in that copied Android SDK. The environment matches the earlier
`android-reminders-home-hunt-20261023.md` report; its listed exports are saved
locally in `.dart_tool/hunt-env.sh`. `DART` was additionally set to
`$RECALL_FLUTTER_ROOT/bin/dart` for the Python tooling suite. The same local
Robolectric init script disables runtime framework downloads; all native test
fixtures are local. Toolchain dependency downloads are separate from tests.

## Final commands and results

| Exact command | Final result |
| --- | --- |
| `./tool/flutterw pub get --offline --enforce-lockfile` | Exit 0; lockfile unchanged. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0; 1,462 passed, 4 skipped. |
| `./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process -Pandroid.builder.sdkDownload=false --init-script "$PWD/.dart_tool/hunt-native.init.gradle"` | Exit 0; 38 JVM tests passed, lint passed, instrumentation APK compiled. `BUILD SUCCESSFUL in 3m 47s`. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 1; 178 tests, 2 failures, 1 skipped. See gate limitations below. |
| `git diff --check` | Exit 0. |

The focused Flutter run also passed (13 tests, exit 0) before the additional
ordering/account/cache regression cases were added:
`./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/offline_deck_counts_test.dart test/decks_count_refresh_test.dart`.
All nine final new Flutter cases ran in the complete suite.

Initial environment-only failures were resolved locally: missing Android API
37.0, absent cached Flutter Android artifacts in Gradle offline mode, and a
Flutter startup conflict between concurrent invocations. Final commands above
completed with the copied pinned SDK. No server, watcher or emulator was started;
Gradle single-use daemons stopped on completion.

## Gate limitations and remaining work

The broad repository tooling gate is **not green**. Its two failures are strict
benchmark source-pin checks, which were preserved without changes:

- `test_cold_start_build_inputs`: the Gradle build-file pin was already stale
  on the starting PR branch. HEAD and this working tree both hash to
  `ea553273c9ddc2a8870cc6ba411a55eef3976d74a6662da35896ca8ddcd73277`, while
  `measure_android_cold_start.BASE_GRADLE_SHA` expects
  `729f278b435614cb6c6060000a3cec7ab9ca1de31d42098a5b693921951beb5d`.
- `test_native_cost_controller_store_fixture_and_patch`: adding the account-scoped
  count cache changes the Store hash. Refresh the frozen native checkpoint-cost
  profile after the runner commits, following
  `tool/fixtures/README-native-checkpoint-cost.md`. That procedure requires the
  full commit containing the changed Store and updates the fixture guards and
  source provenance together. The production review Controller and experimental
  checkpoint patch are unchanged.

No single `make check` exists; the documented local application gate (analysis,
complete maintained Flutter suite, native unit/lint/instrumentation compilation)
ran successfully. The additional tooling failure prevents claiming a fully green
repository/CI gate. Other unrelated CI lanes and physical-device acceptance were
not run.

Offline values remain the last server aggregate baseline adjusted for pending
local reviews; they cannot observe changes made on another device while offline.
A first offline launch without a count cache remains unavailable rather than
inventing totals from a capped study queue. Legacy outbox entries lacking deck
metadata are preserved and not assigned guessed buckets; their counts converge
on successful replay and server refresh. Native notification behavior was checked
with Robolectric, not an installed phone or OEM alarm delivery.

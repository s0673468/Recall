# Offline deck counts and stale Android reminders — 2026-10-23

The ticket's two follow-ups are implemented. No existing tests were edited or
deleted. Git metadata/remotes were not changed; the runner owns the commit.

## Behavior

- Decks retains an account-scoped server baseline. Pending reviews subtract
  each distinct card once from its original due/new bucket. Reviews carry
  local-only deck, previous-state and previous-due metadata; future-due cards
  cannot subtract from an earlier due bucket and counts cannot go negative.
- A count response cannot prove whether a timed-out upload already reached the
  server. While any review is pending, online and offline reads retain the
  established baseline and its overlay. A fresh aggregate is accepted only
  across an empty, unchanged outbox boundary. New reviews or acknowledgements
  crossing a fetch invalidate its result. Aggregates from overlapping or
  owner-expired requests cannot replace the newest baseline.
- Before removing acknowledged reviews, the store persists their count
  adjustment and per-card coverage in that same baseline. A failed refresh
  therefore cannot restore completed work. If either local write is interrupted,
  the remaining outbox can replay safely: coverage prevents another subtraction.
  Undo removes only its pending overlay. A later successful aggregate replaces
  coverage wholesale. Sign-out clears the snapshot with the other account caches.
- The count-cache payload is now version 2. Older disposable snapshots may
  already contain a double-subtracted baseline, so they are unavailable until
  the outbox drains and a successful server read establishes a new baseline.
  Pending reviews themselves are preserved unchanged.
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

## Original implementation commands and results

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

Offline values remain the last accepted server baseline adjusted for pending
and acknowledged local reviews until a safe successful refresh replaces it.
They cannot observe changes made on another device while offline or while local
reviews remain unresolved. Without a compatible baseline, counts stay unavailable
until pending reviews drain and a fresh aggregate succeeds. Legacy outbox entries
without deck metadata are preserved; their buckets are not guessed. Native
notification behavior was checked with Robolectric, not an installed phone or
OEM alarm delivery.

## Review corrections and validation

Both P2 findings reproduced against the starting implementation using the new
synthetic regressions: the lost-ACK case returned zero instead of one due card;
the post-upload refresh failure returned two instead of one (exit 1). The fixes
above address both. `test/offline_deck_counts_reconciliation_test.dart` adds 16
cases, including due/new drains, attempted-but-unaccepted uploads, partial drains,
undo, same-card deduplication, in-flight responses, another Store's ACK, account
isolation, old-cache rejection, refused writes and lost local acknowledgements.
No existing tests were edited or deleted. Android reminder code is unchanged.

The commands below use the checkout-local environment from
`.dart_tool/hunt-env.sh`, `DART="$RECALL_FLUTTER_ROOT/bin/dart"` for Python,
and the available JDK via
`JAVA_HOME=/home/ger/.local/share/fleet-toolchains/temurin-17` for Gradle. No
Apple mobile build or test, real service, personal fixture or credential was used.

| Exact command | Review result |
| --- | --- |
| `./tool/flutterw pub get --offline --enforce-lockfile` | Exit 0; lockfile unchanged. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/offline_deck_counts_reconciliation_test.dart test/offline_deck_counts_test.dart test/decks_count_refresh_test.dart` | Exit 0; 32 passed. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0; 1,478 passed, 4 skipped. |
| `./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process -Pandroid.builder.sdkDownload=false --init-script "$PWD/.dart_tool/hunt-native.init.gradle"` | Exit 0; build successful, native unit outputs reused; lint and instrumentation compilation passed. |
| `./android/gradlew -p android :app:testDebugUnitTest --rerun --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process -Pandroid.builder.sdkDownload=false --init-script "$PWD/.dart_tool/hunt-native.init.gradle"` | Exit 0; forced execution: 38 tests, zero failures/errors/skips. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 1; 178 tests, two source-pin failures, one skipped, no errors. |
| `git diff --check` | Exit 0. |

Both tooling source-pin failures also mismatch the starting HEAD; the Gradle
source is unchanged by these corrections. The Store pin additionally needs to
cover the new snapshot helper when the frozen experiment is requalified. The
profile documentation requires a committed source revision and coordinated
fixture/provenance updates; its guards and existing tests were preserved. The
full local application gate passes, but the repository tooling gate remains red.

Git metadata is read-only in this job. The runner owns the commit; no commit,
push, PR or remote change was attempted. Suggested commit message:
`Fix offline deck count reconciliation across review delivery`.

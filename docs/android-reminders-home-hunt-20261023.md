# Android reminders and deck-count hunt — 2026-10-23

Read README and the earlier `docs/*hunt*` reports first. This checkout has no
AGENTS.md. The supplied task rules apply. Existing accessibility files from
#174 and `review_controller.dart` (#175) were left untouched. No existing test
was edited or deleted. The runner owns the commit; no Git metadata, remotes,
PRs, personal records, accounts or credentials were changed. No fleet checks,
Apple mobile commands, device installation or messages were used.

## Fixed findings

1. **A count/foreground refresh could skip a delayed reminder.** The Dart
   reminder signature includes the due count and foreground reconciliation is
   forced. Native `apply()` cancelled the existing inexact alarm and computed
   the next future slot. At 19:10, an undelivered 19:00 alarm therefore became
   tomorrow's reminder. Native scheduling now remembers the pending timestamp
   and retains it when it matches today's requested wall-time target. A past
   pending target is handed back to AlarmManager for overdue delivery rather
   than skipped. Different reminder times, expired calendar dates, consumed or
   cancelled eligibility, and fresh late enables still choose the appropriate
   future slot. Restore broadcasts continue recalculating local time. The clock
   is an optional explicit input for deterministic scheduler tests; production
   callers retain the system-clock default.

   `RecallReminderReconciliationTest.kt` exercises the actual scheduler,
   SharedPreferences and AlarmManager through Robolectric on API 28 and 35,
   with exact-alarm access disabled. Its eight cases cover overdue preservation,
   changed times, consumption, reboot/update restoration, timezone restoration,
   expired targets, late enable, and ineligible cancellation. With the clock
   seam but the original scheduling algorithm, the initial five-case suite had
   one failure: expected October 23 at 19:00 BRT, received October 24 at 19:00.
   The other four cases passed. The final sixteen cases all pass. Existing
   spring-gap and fall-back tests are unchanged.

2. **The visible deck list retained old counts after refreshed controller data
   or review sync.** Its count future was created only on mount, manual reload,
   or tab entry. A completed queue load replaced the deck list without fetching
   matching counts. An outbox drain could also update Study without replacing
   that list. The screen now listens for deck-list replacements and decreasing
   pending-review counts, and refreshes its count future. Ordinary answer,
   notice and unchanged pending-count notifications do not query again. It
   detaches/rebinds the listener with the widget lifecycle and contains async
   reload errors while the existing count-error surface presents them.

3. **Empty decks lost their count labels despite a successful count fetch.**
   `deck_counts()` groups eligible cards by deck, so an empty deck has no map
   entry. The screen treated that absence like unknown counts. A successful
   result now supplies zero for an absent deck; loading and failed results
   retain the existing unknown/error presentation.

`test/decks_count_refresh_test.dart` adds seven synthetic widget cases: queue
refresh, outbox drain, empty results, overlapping requests, automatic refresh
failure, manual refresh failure, and replacement-controller lifecycle. The
initial queue-refresh and empty-deck regressions both failed on original source
(exit 1); the manual-error control passed. The screen is exercised through
rendered count labels rather than source-string assertions.

## Remaining follow-up candidates and acceptance limits

- Deck counts remain server aggregates. Before offline reviews upload, their
  per-deck values can disagree with Study's locally advanced queue. This change
  refreshes after draining but does not invent a per-deck overlay from incomplete
  local metadata.
- Native `cancel()` clears alarms and eligibility, but does not withdraw an
  already displayed reminder notification. Its displayed-notification lifecycle
  remains a separate follow-up; no new device claim is made for it.
- Notification readiness still checks API 33+ runtime permission plus app/channel
  blocking. Scheduling remains inexact and requests no exact-alarm permission.
  Existing permission/bridge, cold/warm deep-link, native-contract and startup
  regression tests ran in the complete suites. No additional defect was
  established in those paths.
- Reboot/update and timezone checks use synthetic native state. The
  instrumentation APK was compiled, not installed or executed. Actual prompt
  interaction, alarm delivery under OEM power management, notification taps,
  physical reboot and an installed-app update were not exercised.

## Validation

Flutter 3.47.1 was copied from the installed pinned SDK into this checkout;
`./tool/flutterw pub get --offline --enforce-lockfile` exited 0 without changing
the lockfile. Package, Gradle, Android SDK and Robolectric framework caches were
copied into ignored repository-local directories. Android platform 37.0 was
installed there. Robolectric 4.16.1 is a test-only dependency. Fixtures are
invented deck IDs/counts, a fixed clock and isolated preferences/alarms; tests
use no live backend or personal data.

Commands ran with the following local environment (the installed JDK 17 was
retained):

```sh
export RECALL_FLUTTER_CACHE_ROOT="$PWD/.dart_tool/hunt-sdk"
export RECALL_FLUTTER_ROOT="$RECALL_FLUTTER_CACHE_ROOT/flutter-3.47.1"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/.dart_tool/hunt-config"
export XDG_CACHE_HOME="$PWD/.dart_tool/hunt-cache"
export XDG_DATA_HOME="$PWD/.dart_tool/hunt-data"
export TMPDIR="$PWD/.dart_tool/hunt-tmp"
export ANDROID_USER_HOME="$PWD/.dart_tool/hunt-android"
export GRADLE_USER_HOME="$PWD/.dart_tool/hunt-gradle"
export ANDROID_HOME="$PWD/.dart_tool/hunt-android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR -Duser.home=$PWD/.dart_tool/hunt-java-home -XX:-UsePerfData"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true PYTHONDONTWRITEBYTECODE=1
```

The ignored `.dart_tool/hunt-native.init.gradle` ensures that Robolectric reads
its two pre-copied Android framework fixtures locally, with runtime network
resolution disabled:

```groovy
allprojects {
    tasks.withType(Test).configureEach {
        systemProperty 'robolectric.offline', 'true'
        systemProperty 'robolectric.dependency.dir', new File(rootDir, '../.dart_tool/hunt-robolectric').canonicalPath
    }
}
```

The fixture files are
`android-all-instrumented-9-robolectric-4913185-2-i7.jar` and
`android-all-instrumented-15-robolectric-13954326-i7.jar`.

| Exact final command | Result |
| --- | --- |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0; 1,453 passed, 4 skipped. |
| `./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process -Pandroid.builder.sdkDownload=false --init-script "$PWD/.dart_tool/hunt-native.init.gradle"` | Exit 0; 28 JVM tests passed, lint passed, instrumentation APK compiled. `BUILD SUCCESSFUL in 2m 10s`. |
| `git diff --check` | Exit 0. |

The focused rendered-deck run also passed (exit 0):
`./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/decks_count_refresh_test.dart`:
7 passed. No server, preview, watcher or emulator was started. Gradle used
single-use daemons that stopped after completion.

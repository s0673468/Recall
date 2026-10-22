# Android storage and reminder hunt — 2026-10-22

Read README first; no repository AGENTS.md exists. Scope: Android/shared Dart
storage, export and reminder code. Used only invented preference records and
repository-local build/test caches. No card/article content, existing tests,
credentials, real data, devices or running application services were changed.
Skipped the fixes from #157–#159. No dependencies or tool versions changed.

## Fixed findings

1. **Failed reminder saves were acknowledged, and failed changes could leave
   an alarm armed.** `lib/features/reminders/application/study_reminder_controller.dart:264`
   applies native eligibility before saving three preference values. Previously,
   a `false` storage result still updated the acknowledged controller value;
   a thrown save left the previously applied alarm active. A refused disable
   could look successful but become enabled again after reconstruction. The
   controller now checks every result, reports failure through the existing
   error path, cancels the applied alarm, reloads the optimistic preference
   cache and permits retry without acknowledging the failed setting.
   `test/study_reminder_write_failure_test.dart:46` covers refused enable and
   false/throwing writes of enabled/hour/minute, cache readback and retry.
   All seven tests failed on the original controller before the fix.

2. **A passed spring DST gap shifted tomorrow's reminder by an hour.**
   `android/app/src/main/kotlin/com/german/health_anki_flutter/RecallReminderTime.kt:20`
   first normalizes today's requested time, then advances to tomorrow when it
   has passed. At noon on 2026-03-08 in New York, 02:30 normalized to 03:30;
   adding a day retained 03:30 on March 9. Reapplying the requested hour/minute
   after advancing restores 02:30. In `RecallReminderDstTest.kt:11`, the original
   source returned epoch 1773041400000 instead of 1773037800000. The other two
   tests preserve upcoming-gap normalization and fall-back calendar arithmetic.

No input validation was tightened. All previously accepted local hour/minute
pairs remain accepted, including a nonexistent spring-gap time (Calendar still
normalizes it for that day). Ordinary times, DST fall-back days, null last-review
signals and saved enabled preferences with currently ineligible study signals
retain their existing behavior. Storage refusal is an operational failure, not
an input-shape rejection. This does not turn the separate native/Dart preference
writes into one crash-atomic transaction; successful fields may survive a partial
save. Cancellation/cache recovery are best-effort if those platform calls also
fail, and the original save error remains visible.

## Checked and rejected as additional findings

| Area | Evidence and disposition |
| --- | --- |
| Local database/schema upgrade | `lib/features/review/data/local_review_store.dart:29`, `:183`, `:211`, `:226`: versioned SharedPreferences records, no local SQL database. Owner claim precedes copies; completion marker follows them; acknowledged native reads and serialized claims allow interrupted migration to retry while preserving legacy records. Existing migration tests cover copy refusal and competing owners. No new defect established. |
| Corrupt/version-mismatched local records | `local_review_store.dart:282`, `:1205`: an unreadable disposable snapshot is ignored; malformed outboxes fail closed rather than becoming empty. No new blanket schema rejection added to legacy pending actions. Previously fixed offline recovery was not changed. |
| Backup/restore round-trip | `android/app/src/main/AndroidManifest.xml:21`, `android/app/src/main/res/xml/data_extraction_rules.xml:3`, `:10`: Android backup and device transfer exclude application data. No application backup archive/import/restore implementation exists in `lib/` or Android code, so there is no supported archive round-trip to repair. No backup was opened. |
| Interrupted export | `android/app/src/main/kotlin/com/german/health_anki_flutter/RecallOperationalDiagnostics.kt:59`, `:68`, `:74`: the diagnostic mirror validates before writing, writes/syncs a temporary sibling, atomically renames and cleans up. `lib/core/diagnostics/operational_diagnostics.dart:306` exports only after storage succeeds. It is a bounded diagnostic mirror, not a user-data backup. No corruption reproduced. |
| Reboot, time-zone changes, disabled reminders | `AndroidManifest.xml:68`, `RecallReminderScheduler.kt:43`, `:48`, `:58`: restore broadcasts recalculate local time; restore requires active eligibility; consume requires a durable clear. `study_reminder_controller.dart:325` suppresses disabled/unknown/zero-due/studied-today states. Existing reminder tests cover these guards. DST rollover was the new finding above. |
| Process death during a study write | `local_review_store.dart:146`, `:1087`, `:1116`, `:1141`: serialized whole-record outbox writes, stable event IDs and uncertain-commit quarantine protect pending actions. Existing synthetic native retry/ACK tests exercise reconstruction and acknowledgement failures. No physical process-kill or power-loss test performed; no new loss reproduced. |
| Sync conflicts and retries | `lib/features/review/data/review_replay.dart:133`, `:164`, `:215`; `scripts/supabase/migrations/008_apply_review_missing_card.sql:135`: newest review owns scheduling, counters merge from server state, and the preferred RPC logs/merges transactionally with event deduplication. The README already documents legacy fallback/undo limitations. No new server/schema change justified; no backend contacted. |

## Validation

Pinned Flutter 3.47.1 was installed with `./tool/bootstrap_flutter`, followed by
`./tool/flutterw pub get`. All mutable caches stayed inside the repository:

```sh
export XDG_CONFIG_HOME="$PWD/.dart_tool/hunt-config"
export XDG_CACHE_HOME="$PWD/.dart_tool/hunt-cache"
export TMPDIR="$PWD/.dart_tool/hunt-tmp"
export RECALL_FLUTTER_CACHE_ROOT="$PWD/.dart_tool/hunt-sdk"
export PUB_CACHE="$PWD/.pub-cache"
```

| Exact command (with the environment above) | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_reminder_write_failure_test.dart` on original source | Exit 1; all 7 regression tests failed. |
| `./tool/flutterw test --no-pub --reporter=failures-only test/study_reminder_write_failure_test.dart test/study_reminder_controller_test.dart` | Exit 0; 22 passed. |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0; 1,238 passed, 2 skipped. Final source tree. |
| `git diff --check` | Exit 0. |

The DST tests were also compiled directly from the production Kotlin source
with Gradle's bundled Kotlin 2.3.0 compiler and the declared JUnit 4.13.2 test
dependency (no project dependency change). Exact supplemental commands:

```sh
hunt_gradle_lib="$PWD/.dart_tool/hunt-gradle/wrapper/dists/gradle-9.4.1-all/eckclv9s5vi9exbmnyvpg2a3h/gradle-9.4.1/lib"
java -XX:-UsePerfData -Djava.io.tmpdir="$TMPDIR" -cp "$hunt_gradle_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath "$hunt_gradle_lib/kotlin-stdlib-2.3.0.jar:$PWD/.dart_tool/hunt-jvm/junit-4.13.2.jar" -d .dart_tool/hunt-jvm/classes android/app/src/main/kotlin/com/german/health_anki_flutter/RecallReminderTime.kt android/app/src/test/kotlin/com/german/health_anki_flutter/RecallReminderDstTest.kt
java -XX:-UsePerfData -Djava.io.tmpdir="$TMPDIR" -cp ".dart_tool/hunt-jvm/classes:.dart_tool/hunt-jvm/*:$hunt_gradle_lib/kotlin-stdlib-2.3.0.jar" org.junit.runner.JUnitCore com.german.health_anki_flutter.RecallReminderDstTest
```

Compilation exited 0. Before the fix, JUnit exited 1 with one failing regression
and two passing controls. After the fix, JUnit exited 0: **3 passed**.

The repository Android gate was run with the same Flutter environment plus:

```sh
export GRADLE_USER_HOME="$PWD/.dart_tool/hunt-gradle"
export ANDROID_USER_HOME="$PWD/.dart_tool/hunt-android"
export ANDROID_HOME="$PWD/.dart_tool/hunt-android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export XDG_DATA_HOME="$PWD/.dart_tool/hunt-data"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR -Duser.home=$PWD/.dart_tool/hunt-java-home -XX:-UsePerfData"
./android/gradlew -p android :app:testDebugUnitTest :app:lintDebug --no-daemon --max-workers=2 -Pkotlin.compiler.execution.strategy=in-process -Pandroid.builder.sdkDownload=false
```

**Exit 0: 12 JVM tests passed and Android lint passed.** Initial attempts
stopped on missing SDK targets/CMake; the required Android 35, 36, 37.0,
build-tools 36.0.0, Flutter-pinned NDK 28.2.13676358 and CMake 3.22.1 were
installed inside the repository, with no project version changes. In-process
Kotlin compilation keeps its state inside the repository instead of trying the
sandbox-blocked default daemon directory. No emulator, device installation,
actual alarm delivery, physical process kill or backend execution was attempted.

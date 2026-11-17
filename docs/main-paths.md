# Main paths: invented data only

Run `./tool/bootstrap_flutter`, `./tool/flutterw pub get`, then `./tool/run_main_paths`.
This runs production app widgets with invented decks, cards, review history and
in-memory settings. It neither reads nor writes an ordinary Recall collection.
The 290-second limit includes test startup after SDK/dependency setup. The existing full Flutter exact-head
suite already runs these same files; the generated day property is included there.
This short run replaces a builder choosing a fresh list of UI tests each time.

| Path | Expected result |
|---|---|
| Open the app | The invented deck and front of a card appear. |
| Reveal and rate | The answer appears; Good advances once and updates the saved count. |
| Review offline, then Undo | One pending review is saved; Undo restores the card and count. |
| Flag a card | The fixture records one flag with the selected reason. |
| Search Decks | The opt-in fixture deck appears in search. |
| Open Stats and Read | Counts, forecast and concept search use the invented collection. |
| Open Settings | Scheduling and per-deck controls remain reachable. |

There is no card-authoring flow in this app: Desktop Anki authors content. The
run never creates or edits German's cards to imitate an unsupported Add action.

## Disposable Android emulator

For a fresh checkout, prebuild the fixture once before timing the paths:
`./tool/flutterw build apk --debug --no-pub --target-platform android-x64 -t integration_test/main_paths_test.dart`.
Cold SDK downloads and the first Android compilation are setup, outside the path clock.
Use a task-local Android user/Gradle home so no existing signing key is read.

Create an **owned, empty** AVD named `recall_prune_fixture` from an installed
x86_64 Android image in task-local `ANDROID_AVD_HOME`, then start it with
`emulator -avd recall_prune_fixture -no-window -no-audio -no-snapshot -gpu swiftshader`.
After boot, write its serial to `$ANDROID_AVD_HOME/.recall-main-paths-owned`.
Pass that explicit serial to `./tool/run_main_paths --emulator emulator-PORT`.
The wrapper checks the ownership marker, emulator serial and AVD name before installing.
`integration_test/main_paths_test.dart` runs the shared normal app traversal
inside Android. The default widget run also keeps the offline-Undo, keyboard and
intentional failure-injection cases. Use two admitted CPUs and 11 GiB for the
emulator plus build; the one-CPU cold setup did not reach the test connection. Do not point it at an existing/signed-in AVD or physical phone.
The integration test uses in-memory preferences and fixture API dependencies.
Stop the owned emulator and remove only its task-local AVD when finished.

To inspect the fixture interactively on that same owned emulator:
`./tool/flutterw run -d emulator-PORT -t tool/recall_acceptance.dart`.
This separate entry point displays a TEST DATA banner and constructs only
invented dependencies. No live runtime config is needed.

## Always-true rules

`test/study_day_properties_test.dart` generates 2,000 deterministic instants:
each belongs to one 24-hour study day starting at 03:00 UTC; adjacent days meet
without overlap; converting a timestamp to local time does not change its day.
Existing FSRS, replay, owner-migration and durable-outbox property/boundary tests
stay. New generated checks do not replace protected data cases.

## Random failures

Do not retry a red test until it happens to pass. Find whether the failure is
product behavior, fixture/tool trouble or machine capacity. Fix its cause and
run the affected test once; preserve the original failure. Delete an obsolete,
unprotected test with a one-line reason. Never hide a failure with a skip, delay,
extra retry or looser data/privacy assertion. Capacity refusal before startup is
not a test failure; obtain admission before starting another attempt.

## Incident checks

See [the incident list](check-incidents.md).

Retired-source deletion remains separate from the test cut. Signing configuration,
credential-handling tools, all data/cache/migration helpers and mixed privacy tests
remain listed and untouched when their role is unclear.

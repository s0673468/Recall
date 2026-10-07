# Android emulator acceptance

The Android matrix is a device acceptance contract, not a count of generated or
mocked tests. Keep its results outside Git in a private task-owned directory.
`tool/android_acceptance_matrix.py` initializes all 2,592 combinations and refuses
to overwrite an existing directory. Each row starts pending. Screen captures,
actual device settings and independent verification are required before acceptance.

## Isolated test app

The separate `tool/android_acceptance.dart` entrypoint uses invented decks and a
durable invented backend journal. It never loads the normal Supabase configuration
or secure session. The acceptance Gradle property gives it the separate package
`com.german.health_anki_flutter.acceptance`, labels it Recall TEST, removes INTERNET
permission, and refuses release builds or an unrelated entrypoint. The screen also
displays TEST DATA. Never substitute this APK for the normal signed APK.

After fleet admission with the pinned Flutter toolchain:

```sh
ORG_GRADLE_PROJECT_recallAndroidAcceptance=true ./tool/flutterw build apk \
  --debug --no-pub --no-android-gradle-daemon \
  --target-platform android-arm64 -t tool/android_acceptance.dart \
  --dart-define=RECALL_ANDROID_ACCEPTANCE=true
```

Use the invented account `learner@example.invalid` and password `invented-only`.
These are fixture literals, not service credentials. The fixture rejects every
other account. Go offline and Reconnect operate the invented backend, independently
of Android connectivity. They must not be reported as real network-loss evidence.

Native preferences store both the actual client outbox and the invented review
ledger. The journal deduplicates stable client event IDs and survives process
reconstruction; the native reminder/background adapters and widget bridge exercise
the app's platform code. This proves no production database, RPC, authentication,
or cross-device behavior. A force-stop/relaunch or upgrade must actually run before
claiming persistence; the focused Dart tests alone do not prove Android storage.

## Evidence requirements

- Record exact source, APK checksum, package, signer, device API/ABI, emulator
  version, profile, locale, font scale, theme and TalkBack state for each attempt.
- Capture screens before/after the real flow; verify clipping, reachable controls,
  accessibility labels and focus traversal. A UI hierarchy alone is not TalkBack
  traversal evidence. A missing TalkBack service blocks those rows.
- Check journal deltas using stable client event IDs. Rating/replay should yield
  one invented review per event. Read-only, flag and hide flows must not create
  review rows. An eligible unsent Undo removes the pending event; an attempted
  delivery must retain the safeguard from PR #91.
- Distinguish real Fold posture changes from `wm size` resizing. Record unsupported
  device states explicitly. System locale/theme changes do not establish app
  translation/theme support; inspect the resulting app.
- Use the same package and signing identity for upgrade tests, preserve a nonempty
  outbox, then read back its delivery exactly once. Two builds of the current
  source do not prove upgrading from an earlier version.
- Native notification delivery, launcher widget placement, deep links, process
  death and offline/reconnect each need their actual Android interaction. Do not
  infer these results from mocked callbacks or APK assembly.

Run `python3 -m unittest discover -s tool/tests -p test_android_acceptance_matrix.py`
for queue contracts and `./tool/flutterw test --no-pub
test/android_acceptance_fixture_test.dart` for the invented journal's contracts.
These checks are prerequisites, not the full emulator matrix or the final gate.

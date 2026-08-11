# Recall native Android setup

Recall's Android app uses the same Flutter screens, Supabase contracts, FSRS
scheduler, offline snapshot, durable review and flag outboxes, reminders,
settings, and statistics as iOS and web. The checked-in Android target is host
and platform integration code; scheduling and data ownership stay in Dart.

## Target

- installed name: **Recall**
- application ID: `com.german.health_anki_flutter`
- minimum Android version: API 24
- compile and target SDK: Flutter's pinned SDK 36 values
- Java language level: 17
- authentication: Supabase email and password with a revocable session in
  Android encrypted storage

The application ID is intentionally historical. It is the identity of the
earlier Recall Android build and must not change without accepting a new app
sandbox. A build can update an installed app only when its application ID and
signing certificate both match.

No password, service-role key, keystore, key password, endpoint, session, or
signing identity belongs in the repository. Runtime configuration may contain
only `SUPABASE_URL` and the public `SUPABASE_ANON_KEY` in the ignored
`config/supabase.local.json` file.

## Build and test

Install Flutter 3.44.2, Android SDK 36, and JDK 17 or newer. Android Studio's
bundled JDK is supported. From the repository root:

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --reporter=failures-only
flutter build apk --debug --no-pub \
  --dart-define-from-file=config/supabase.local.json
```

Run the native JVM and instrumentation build checks with the checked-in Gradle
configuration. Flutter generates the ignored wrapper launcher and local SDK
path when needed.

```bash
cd android
JAVA_HOME="/path/to/jdk-17-or-newer" ./gradlew testDebugUnitTest
JAVA_HOME="/path/to/jdk-17-or-newer" ./gradlew assembleDebug assembleDebugAndroidTest
```

Use the profile build for on-device frame and startup measurements:

```bash
flutter build apk --profile --no-pub \
  --dart-define-from-file=config/supabase.local.json
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

## Release signing

Release builds fail closed unless `android/key.properties` selects an ignored
private keystore. Copy `android/key.properties.example`, fill it locally, keep
the keystore outside version control, and follow Flutter's Android signing
guide. Protect and back up the original keystore: a different certificate
cannot update an existing installation.

```bash
flutter build apk --release --no-pub \
  --dart-define-from-file=config/supabase.local.json
```

For continuity testing against the historical debug-signed installation only,
a throwaway release-optimized APK can explicitly opt into the local Android
debug certificate:

```bash
ORG_GRADLE_PROJECT_allowDebugReleaseSigning=true \
  flutter build apk --release --no-pub \
  --dart-define-from-file=config/supabase.local.json
```

That opt-in is not production signing and must not be used for distribution.
Never uninstall an existing Recall app to work around a signing mismatch: first
prove its durable review and flag outboxes are empty or safely replayed.

Before any update, read the installed identity and version, then preserve app
data with `adb install -r`:

```bash
adb shell pm path com.german.health_anki_flutter
adb shell dumpsys package com.german.health_anki_flutter
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell dumpsys package com.german.health_anki_flutter
```

## Android behavior

- `recall://study` is the only custom deep link. Flutter's automatic manifest
  deep-link handler is disabled so `app_links` receives it exactly once.
- API 33 notification permission is requested only after a signed-in user
  enables reminders. Recall uses an inexact alarm, requests no exact-alarm
  access, and rearms after delivery, reboot, clock, or time-zone changes.
- Reminder and widget surfaces contain aggregate text only. Both open Study
  through an explicit immutable `PendingIntent`.
- Supabase remains the source of truth. Foreground, resume, and validated
  network-reconnect paths drain the same durable idempotent review and flag
  outboxes. Android schedules no hidden headless account work.
- Backup and cleartext traffic are disabled. The diagnostics mirror is bounded,
  value-free, private, atomic, and excluded from backup.
- Android 16 edge-to-edge and predictive back are enabled. Narrow screens use a
  Material navigation bar; wide windows use a navigation rail and remain
  resizable across rotation and large-screen layouts.
- Study haptics use platform feedback only for reveal, rating, undo, and flag
  confirmation. Android's system haptic setting is respected; no vibration
  permission is requested.
- The launcher shortcut and home-screen widget open Study. The widget shows
  only the all-decks due count and whether its aggregate snapshot is stale.

Passkeys are not enabled. The current product has no passkey flow, and Android
passkeys require coordinated Supabase Auth enablement, a relying-party domain,
Digital Asset Links, and final signing fingerprints. Email/password remains the
supported authentication path until those production prerequisites are
deliberately configured and verified.

## Device acceptance

Use the exact connected device model and build fingerprint rather than assuming
a Pixel model. Preserve the user's data and system settings.

- prove cold and warm launch, restored-session or interactive authentication,
  all primary destinations, Study back behavior, deep-link routing, and sign-out
- verify rich HTML, cloze, LaTeX/media, four FSRS previews, review, undo, flag,
  offline persistence, restart, reconnect replay, and duplicate suppression
- check portrait and landscape, split/large-window behavior, large text, touch
  targets, semantics, reduced animation scale, and predictive back
- test reminder permission timing, notification tap, reboot/time-zone rearm,
  widget freshness/action, launcher shortcut, and system-disabled haptics
- capture private-data-free screenshots plus cold/warm startup and frame timing
  evidence, then restore any changed rotation, font, animation, or haptic setting
- read back the installed package, version name/code, and signing certificate

Current platform references:

- [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
- [Android 16 SDK setup](https://developer.android.com/about/versions/16/setup-sdk)
- [Flutter edge-to-edge migration](https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge)
- [Flutter predictive back migration](https://docs.flutter.dev/release/breaking-changes/android-predictive-back)
- [Android adaptive orientation and resizability](https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability)
- [Android notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission)
- [Android alarms](https://developer.android.com/develop/background-work/services/alarms)
- [Android haptic feedback](https://developer.android.com/develop/ui/views/haptics/haptic-feedback)
- [Supabase passkey prerequisites](https://supabase.com/docs/guides/auth/passkeys)

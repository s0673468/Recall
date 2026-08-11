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

Run the native JVM and instrumentation build checks with the checked-in,
checksum-validated Gradle wrapper. Flutter writes only the ignored local SDK
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

Release builds fail closed unless `android/key.properties` selects one of two
explicit signing modes. `private` uses a normal ignored private keystore. Copy
`android/key.properties.example`, fill it locally, keep the keystore outside
version control, and follow Flutter's Android signing guide.

The already-distributed Android app has a historical debug certificate. On a
machine where the installed certificate has first been proven to match the
retained key, preserve that exact identity in Recall's owner-only signing
directory and select the password-free continuity profile:

```bash
install -d -m 0700 "$HOME/Library/Application Support/Recall/signing"
install -m 0600 "$HOME/.android/debug.keystore" \
  "$HOME/Library/Application Support/Recall/signing/recall-historical.keystore"
install -m 0600 android/key.properties.historical.example android/key.properties
```

This moves continuity away from Android's auto-managed debug location without
changing the certificate. It is appropriate for in-place private sideloads,
not Google Play distribution or a passkey origin. Back up the owner-only file;
a different certificate cannot update an existing installation.

```bash
flutter build apk --release --no-pub \
  --dart-define-from-file=config/supabase.local.json
```

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
  enables reminders. Recall also detects app- or channel-level notification
  blocking and offers a direct system Settings action. It uses an inexact
  alarm, requests no exact-alarm access, and rearms after delivery, reboot,
  clock, or time-zone changes.
- Reminder and widget surfaces contain aggregate text only. Both open Study
  through an explicit immutable `PendingIntent`.
- Supabase remains the source of truth. Foreground, resume, and every transition
  back to a validated network drain the same durable idempotent review and flag
  outboxes. Android schedules no hidden headless account work.
- Backup and cleartext traffic are disabled. The diagnostics mirror is bounded,
  value-free, private, atomic, and excluded from backup.
- Android 16+ edge-to-edge and predictive back are enabled. Narrow screens use a
  Material navigation bar; wide windows use a navigation rail and remain
  resizable across rotation and large-screen layouts.
- Study haptics use platform feedback only for reveal, rating, undo, and queue
  completion. Android's system haptic setting is respected; no vibration
  permission is requested.
- The launcher shortcut and home-screen widget open Study. The widget shows
  only the all-decks due count and whether its aggregate snapshot is stale.

## iOS parity and Android conventions

The native apps share one Flutter product surface. Study, Decks, Stats, Read,
FSRS scheduling and previews, rich HTML/LaTeX/media cards, flags, catch-up,
preferences, auth/session handling, the offline snapshot, and both durable
outboxes have no Android fork.

Every maintained iOS integration has an Android equivalent behind the same
method-channel contract:

- the iOS widget becomes a resizable `RemoteViews` home-screen widget, plus an
  Android launcher shortcut;
- the iOS calendar notification becomes a permission-aware inexact Android
  alarm that survives reboot, app replacement, clock, and time-zone changes;
- iOS background fetch and Android validated-network reconnect both invoke the
  same bounded Dart outbox drain. Android additionally drains on foreground and
  resume and deliberately does not start hidden headless account work;
- both platforms mirror only the closed operational-event schema into private,
  backup-excluded storage;
- both use the canonical Recall icon artwork. Android supplies it as adaptive
  foreground, background, and monochrome layers so launcher masks and themed
  icons remain native.

The visible differences are intentional platform conventions. iOS uses
Cupertino tabs, sheets, time selection, and page transitions. Android uses
Material navigation, bottom sheets, the system time picker, navigation rail on
wide windows, edge-to-edge system bars, and predictive back. These differences
do not change Recall's data, scheduling, or offline guarantees.

On Android 17, target-SDK 36 apps receive `ACCESS_LOCAL_NETWORK` implicitly
through `INTERNET`. Recall does not declare or request that runtime permission
and has no LAN feature. When Flutter's supported template moves to target SDK
37, Recall should keep LAN access blocked rather than add the broad permission.

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
- [Android 17 local-network permission](https://developer.android.com/privacy-and-security/local-network-permission)
- [Android alarms](https://developer.android.com/develop/background-work/services/alarms)
- [Android haptic feedback](https://developer.android.com/develop/ui/views/haptics/haptic-feedback)
- [Supabase passkey prerequisites](https://supabase.com/docs/guides/auth/passkeys)

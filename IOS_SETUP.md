# Recall native iOS setup

Recall's PWA and native iPhone app use the same Flutter screens, Supabase
contracts, FSRS scheduler, cache, review/flag outboxes, undo, settings, and
stats. The checked-in iOS target is delivery plumbing only; scheduling and data
logic stay in Dart so the two surfaces cannot drift.

## Target

- installed name: **Recall**
- bundle identifier: `com.german.ankiReview`
- minimum version: iOS 16
- device family: iPhone
- orientation: portrait
- authentication: interactive Supabase sign-in once; the revocable session is
  stored in the iOS Keychain and Face ID or the device passcode unlocks Recall

No account password, service-role key, signing identity, or provisioning profile
belongs in the repository. The build input may contain only `SUPABASE_URL` and
the public `SUPABASE_ANON_KEY`.

## Build

```bash
cd health-apps/health_anki_flutter
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --reporter=failures-only
flutter build ios --simulator --debug \
  --dart-define-from-file=config/supabase.local.json
```

For a personal-device build, open `ios/Runner.xcworkspace` in Xcode, select the
Runner target, enable automatic signing, choose German's Apple Developer team,
and select the connected iPhone. Do not commit the selected team or any locally
generated signing files.

After device validation, build a release archive with:

```bash
flutter build ipa --release \
  --dart-define-from-file=config/supabase.local.json
```

## PWA-to-native cutover

Safari/PWA storage and the iOS app sandbox are separate. Before switching:

1. Open the PWA online and verify the Study header has no `syncing` badge.
2. Keep the PWA installed as a fallback until the device checks below pass.
3. Install Recall and sign in once; the browser's Supabase session and local
   snapshot cannot migrate into the app automatically.
4. Confirm a review, undo, and card flag reach the existing cloud account.

Recall now fails sign-out closed. It flushes and verifies both durable outboxes
before clearing the local cache, secure session, or the account's reminder. If
the phone is offline or local outbox storage is malformed, sign-out stops and
shows the recovery error while preserving the pending work. Review replay uses a
stable event identity so a lost cloud acknowledgement does not create a second
review-log row.

Daily study reminders are stored per Supabase user and are released only after
that user's sign-out succeeds. Foreground and iOS background sync drain the
same durable review/flag outboxes; neither path deletes an entry that did not
reach Supabase. The WidgetKit bridge publishes only the verified all-decks due
count and its cloud refresh time. See `ios/RecallWidget/README.md` for App Group
signing and the guarded Personal Team fallback.

Before releasing the idempotent native outbox path, apply
`scripts/supabase_migrate_recall_idempotency.sql` to the Recall Supabase
project. It adds nullable event IDs plus unique indexes; existing rows are not
rewritten. The client retains a rolling-deploy fallback for an older schema,
but server-enforced duplicate protection begins only after this migration.

## Required iPhone 15 Pro Max checks

- cold launch, restored session, manual login, and Face ID success/cancel
- Study, Decks, Stats, Settings, rich HTML, cloze, and LaTeX parity with the PWA
- four FSRS rating previews, review, single-level undo, and flag reasons
- portrait safe areas and reachable rating buttons at default and large text
- airplane-mode launch from a cached queue, queued ratings, reconnect, and
  foreground sync
- terminate/reopen around an offline review and verify no duplicate cloud log
- daily reminder permission, time change, tap-to-Study, and account switching
- background an offline rating, reconnect, and verify the outbox drains
- widget all-decks count, stale timestamp, and Start Study App Intent
- app icon, display name, ProMotion scrolling, and release signing

## Regenerate the app icons

Recall's iOS and web icons share the constructed geometric R in
`health-apps/tool/render_launcher_icons.py`. Its stem and leg end on the same
baseline, and the renderer reads every required size from the iOS asset
catalog. From the repository root:

```bash
python3 health-apps/tool/render_ios_icon_sets.py --app recall
python3 health-apps/tool/render_web_icon_sets.py --app recall
```

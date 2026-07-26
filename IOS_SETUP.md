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
# From the repository root.
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

## Personal TestFlight delivery

The paid-team delivery lane uses Xcode Cloud only for an intentional personal
beta, not for every commit. GitHub CI remains the validation gate; start the
cloud workflow only from the exact green `main` commit that German wants on the
iPhone.

### One-time App Store Connect setup

1. Create the iOS app record for bundle ID `com.german.ankiReview`.
2. Under TestFlight, create one internal group named `German` and add the
   Account Holder as its only tester.
3. In Xcode, configure Xcode Cloud for `ios/Runner.xcworkspace`, product
   `Runner`, and the shared `Runner` scheme.
4. Keep the workflow manual. Add one iOS Archive action with deployment
   preparation **Internal Testing Only**, then add a TestFlight Internal
   Testing post-action targeting the `German` group.
5. Add `RECALL_SUPABASE_CONFIG_B64` to the workflow environment and mark it
   **Secret**. Its decoded JSON must contain exactly `SUPABASE_URL` and
   `SUPABASE_ANON_KEY`; no login, service-role, or signing credential is
   allowed.

To place the protected local config on the clipboard without printing it:

```bash
/usr/bin/base64 < config/supabase.local.json | pbcopy
```

Paste that value into the secret workflow variable. The checked-in
`ios/ci_scripts/ci_post_clone.sh` sits beside `Runner.xcworkspace`, as Xcode
Cloud requires. It installs pinned Flutter 3.44.2, reconstructs and validates
the ignored config, runs `flutter pub get`, and prepares the Release archive
with Xcode Cloud's unique `CI_BUILD_NUMBER`.
`ios/ci_scripts/ci_post_xcodebuild.sh` removes the reconstructed file after
the Xcode action. Xcode Cloud's environment is temporary, and the runtime
config is compiled through Dart defines rather than bundled as an asset.

On the iPhone, accept the internal invitation in TestFlight and enable
automatic updates for Recall. Use TestFlight's **Update** button when a build
is needed immediately; background automatic installation is not
instantaneous. Each beta build expires after 90 days, so keep publishing
current builds while TestFlight is Recall's primary installation.

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

Recall's iOS and web icons share the constructed geometric R rendered by the
`render_launcher_icons.py` / `render_ios_icon_sets.py` / `render_web_icon_sets.py`
tooling. That icon tooling was **not** moved out of Health in slim phase 2 — it
still lives under `health-apps/tool/` in the Health repo and is shared across the
Health app icons. To regenerate Recall's icons, run it from a Health checkout:

```bash
# from a Health checkout
python3 health-apps/tool/render_ios_icon_sets.py --app recall
python3 health-apps/tool/render_web_icon_sets.py --app recall
```

The already-rendered icon assets are committed in this repo, so a rebuild only
needs the tooling when the mark itself changes.

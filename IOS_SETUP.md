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
  stored in the iOS Keychain and opens Recall directly until sign-out

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

The standalone Recall repository has a configured manual Xcode Cloud workflow
named **Recall Internal TestFlight**. It archives the protected `main` branch
for app `com.german.ankiReview` and delivers successful builds to the internal
**German** group.

### Validated Apple setup

- [x] Use the paid Apple Developer Program team. Register the main App ID
  `com.german.ankiReview` and the widget App ID
  `com.german.ankiReview.RecallWidget` if needed. Register the App Group
  `group.com.german.ankiReview` and attach it to both App IDs. Create the iOS
  app record named **Recall** for the main App ID.
- [x] Under TestFlight, create the internal group **German**. Add the Account
  Holder as its only tester.
- [x] Open `ios/Runner.xcworkspace` in Xcode. Choose Integrate > Create
  Workflow. Select product `Runner` and the shared `Runner` scheme. Grant Xcode
  Cloud access to `github.com/s0673468/Recall`.
- [x] Name the workflow **Recall Internal TestFlight**. Keep its start
  condition manual.
- [x] Add one iOS Archive action with deployment preparation **Internal
  Testing Only**. Add a TestFlight Internal Testing post-action for the
  **German** group.
- [x] Add `RECALL_SUPABASE_CONFIG_B64` to the workflow environment and mark it
  **Secret**. Its decoded JSON must contain only `SUPABASE_URL` and the public
  `SUPABASE_ANON_KEY`.
- [x] Keep `ITSAppUsesNonExemptEncryption` set to `false` in
  `ios/Runner/Info.plist`. This source-controlled declaration prevents each
  build from stopping at a manual export-compliance prompt.
- [x] In App Store Connect > Users and Access > Integrations, create a Team API
  key with Developer access. Download it once. Save it as
  `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.
- [x] Set `ASC_KEY_ID` to that key's Key ID. Set `ASC_ISSUER_ID` to the Issuer
  ID shown on the Integrations page. Keep both values out of the repository.
  Keep the private key owner-owned and mode `0600`.

To place the protected local config on the clipboard without printing it:

```bash
/usr/bin/base64 < config/supabase.local.json | pbcopy
```

Paste that value into the secret workflow variable. The checked-in
`ios/ci_scripts/ci_post_clone.sh` sits beside `Runner.xcworkspace`, as Xcode
Cloud requires. It installs pinned Flutter 3.44.9, reconstructs and validates
the ignored config, runs `flutter pub get`, and prepares the Release archive
with Xcode Cloud's unique `CI_BUILD_NUMBER`.
`ios/ci_scripts/ci_post_xcodebuild.sh` removes the reconstructed file after
the Xcode action. Xcode Cloud's environment is temporary, and the runtime
config is compiled through Dart defines rather than bundled as an asset.

Shipping and waiting for the cloud build is one command:

```bash
python3 scripts/testflight_build.py
```

The script first proves that the exact `main` tip is protected by strict,
successful required GitHub checks. It then resolves the standalone product by
bundle ID `com.german.ankiReview`, the exact workflow, repository, and branch.
It rechecks the branch tip immediately before starting the build.

Completion means more than a green Xcode Cloud archive. The script verifies the
cloud run used the gated commit, waits for App Store Connect to mark the build
`VALID`, confirms the non-exempt-encryption declaration, and proves that the
build is attached to the internal **German** group with at least one eligible
tester. Use `--workflow <name>` or `--branch <name>` to override either default.

Before shipping, confirm setup without starting a build:

```bash
python3 scripts/testflight_build.py --dry-run
```

The script never prints the API key, private key, or generated token. Run
`python3 scripts/testflight_build.py --help` for the same environment-variable
and key-path requirements.

On the iPhone, accept the internal invitation in TestFlight and enable
automatic updates for Recall. The first Install or Update tap is still a
phone-side boundary. Each beta build expires after 90 days.

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

- cold launch, restored session opening directly, manual login, and sign-out
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

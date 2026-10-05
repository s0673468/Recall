# Recall website

Open [Recall](https://s0673468.github.io/Recall/) and sign in with the same
Recall account used on Android. The website is the same Flutter application,
with the same Supabase backend, FSRS scheduler, card renderer, and account-scoped
study settings. It does not import a second copy of your collection.

## Browser layout and features

Wide browser windows use side navigation for Study, Decks, Stats, and Read,
with a direct Settings action. Narrow windows keep the mobile bottom tabs.
Resizing preserves the selected tab, search, scroll, and study session.
Content keeps Recall's graphite canvas, yellow selection accent, typography,
and comfortable reading width.

The website includes reviewing and interval previews, undo, card flags and
one-tap hiding, automatic and manual deck selection, statistics and forecasts,
concept primers, recent reading and weekly chat pages, and scheduling settings.
Space reveals an answer; keys 1–4 rate it after reveal. Settings and reading
pages remain accessible with the keyboard.

Native daily reminder notifications, home-screen widgets, secure OS storage,
and haptics are device integrations. They remain available in the Android/iOS
apps; the website uses browser storage and does not promise scheduled delivery
after its tab closes. The website can be installed as a PWA using the browser's
install or Add to Home Screen action.

## Synchronization

Supabase remains the authority for cards, review history, scheduling, flags,
and study settings on every platform. Reviews and flags made without a
connection remain in the existing durable outboxes and replay on reconnect.
Pending settings are account scoped and replay before cloud settings are read.

An open, visible, online browser tab catches up once a minute, and immediately
on reconnect or returning to the page. Wake signals share one serialized sync
path: pending writes are delivered first, then an idle study queue refreshes.
An active card is preserved so a background refresh cannot replace a question
or answer while you are studying. Use Reload to explicitly reload that queue;
Decks, Stats, and Read refresh through their existing tab/refresh controls.
Hidden, offline, and signed-out tabs do not poll.

Undo is still the Android app's single-level session action. Local disposable
remediation and catch-up presentation state retain the existing device-local
behavior; they do not become a second cloud scheduling authority. Keep one
active Recall tab per browser while reviewing offline: browser storage is
shared across tabs, but write serialization is scoped to an app process.

## Development and deployment

From the repository root:

```bash
./tool/flutterw pub get
./tool/flutterw run -d chrome \
  --dart-define-from-file=config/supabase.local.json
./tool/flutterw build web --release --no-pub --base-href /Recall/ \
  --no-web-resources-cdn \
  --dart-define-from-file=config/supabase.local.json
```

Use only `SUPABASE_URL` and `SUPABASE_ANON_KEY` in build configuration. Never
bundle a password, service-role key, or automatic sign-in credentials. The
existing Pages workflow deploys the protected `main` build after merge.
The versioned service worker activates a new bundle after old tabs close;
close other Recall tabs and reopen if an older layout remains visible.

For isolated testing with synthetic data and no production connection, use
the commands and workflow inventory in
[product acceptance](docs/product-acceptance.md). A fixture pass proves app
behavior, not live account access or cross-device delivery. Live acceptance
requires an authenticated browser and the Android app to observe the same
account; do not create real reviews merely to populate a test screenshot.

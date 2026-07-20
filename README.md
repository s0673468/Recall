# Recall

Cross-platform Anki review app. Standalone spaced-repetition review product
(own Supabase project, own FSRS engine) — no coupling to any Health data.

## Provenance

Recall was moved out of the Health monorepo in **Health slim phase 2**
(moved from Health @ `39caf0d2`; the pre-move state is tagged `pre-slim2-2026-07`
in the Health repo). Full app history is preserved here — this repo's `main` was
created with `git subtree split` of `health-apps/health_anki_flutter/`, so every
original commit is intact with paths rewritten to the repo root.

The ~10 generic UI/auth symbols Recall used to import from Health's
`health_flutter_shared` package (AuthGate, SignOutButton, SectionCard,
AppSwitcher, the secure-session storage, the design-system tokens / UiScore,
`scopedPanelColor`, `AppScrollBehavior`) are now **vendored** verbatim under
[`lib/vendored/`](lib/vendored/) — the app builds with zero dependency on any
Health repo package. The Dart package name stays `health_anki_flutter` (renaming
it would churn every internal import for no functional gain).

The Anki *collector* that feeds `anki_*` study fields into Health's
`health_daily` is a separate concern and **stays in Health** — moving the app is
not removing that data source.

## Role

- reads decks, due cards, new cards, recent reviews, and per-deck counts from
  its own Supabase project
- schedules ratings with FSRS
- stores a local snapshot and durable review outbox so offline reviews are not
  lost
- reuses the vendored Health design system + auth shell
- runs as the Recall browser/PWA surface and as an installable iPhone app from
  the same tested Flutter codebase

## Data ownership

**Recall's Supabase project is the source of truth for all review and
scheduling state.** Everything on the device is cache or an outbound write
buffer — never an authority.

- **Supabase = truth.** Cards, notes, per-card FSRS scheduling state
  (`stability`/`difficulty`/`due`/`state`/`reps`/`lapses`/`last_review`), the
  append-only `review_log`, and study preferences (`user_settings`) all live in
  Supabase, scoped per user by row-level security.
- **Device state = disposable cache.** The local snapshot (last-loaded decks +
  study queue, `recall_snapshot_v1`) and the mirrored study prefs
  (`recall_prefs_v1`) are pure cache: they paint instantly on a cold open and
  are **rebuildable and discardable**. Every successful server fetch replaces
  them wholesale; a fresh cloud read on load/foreground always wins over what
  was cached. Wiping local storage loses nothing but paint latency.
- **The outbox is a pending *write*, not a competing source of truth.** Reviews
  and card flags taken offline are appended to a durable, append-only outbox
  (`recall_outbox_v1` / `flag_outbox_v1`) and replayed to Supabase at the next
  launch/foreground. This is the one piece of device state that is **not**
  freely discardable — it holds user actions that have not yet reached the
  server, so sign-out is fail-closed on a non-empty outbox. It never makes the
  device authoritative: it only carries local actions *toward* the server, which
  remains truth once they land.
- **Conflicts resolve server-wins for anything the device only reads** (queue,
  counts, prefs on load). Replayed reviews are deduplicated server-side by a
  durable `client_event_id` so a retry can never double-apply or log twice.
- **Desktop Anki authors content; Recall (web/app) owns scheduling.** The
  desktop importer is the sole author of cards/notes and sets `suspended` /
  `deleted` one-way; Recall never creates or edits card content. Recall owns the
  *review/scheduling* half: it computes FSRS outcomes and writes the resulting
  scheduling state + review log back to Supabase.

### Known divergences from strict server-wins

Two write paths use last-write-wins rather than a server-version guard. Both are
tolerable for a single user across a handful of devices, but they are the spots
where a *stale local write* can overwrite a fresher server value:

- **Outbox replay overwrites the `cards` row unconditionally** (`RecallApi`
  `_updateCard`, `lib/features/review/data/recall_api.dart`). The
  `client_event_id` idempotency guard dedupes the *same* review, but does not
  compare `last_review`/`due` timestamps. If the same card were reviewed offline
  on device A while device B reviewed and synced it, device A's later flush would
  overwrite device B's newer scheduling with the older locally-computed state.
- **Study prefs write-through is last-write-wins** (`RecallPrefsController`,
  `lib/features/settings/application/recall_prefs_controller.dart`). The cloud
  row replaces the local mirror on load, but an offline prefs edit can overwrite
  a newer cloud value when it later writes through.

Neither is fixed here (docs-only change); they are recorded so the doctrine
matches real behavior.

## Local commands

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --reporter=failures-only
flutter run -d chrome --dart-define-from-file=config/supabase.local.json
flutter build ios --simulator --debug \
  --dart-define-from-file=config/supabase.local.json
```

Use `config/supabase.local.example.json` for local bootstrapping only. Keep the
build input to `SUPABASE_URL` plus `SUPABASE_ANON_KEY`; user access still goes
through interactive auth and row-level security.

See [IOS_SETUP.md](IOS_SETUP.md) for signing, device installation, PWA cutover,
and the required iPhone 15 Pro Max checks.

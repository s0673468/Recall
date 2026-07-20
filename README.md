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

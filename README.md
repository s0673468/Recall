# Recall

Cross-platform Anki review app for the Health workspace.

## Role

- reads decks, due cards, new cards, recent reviews, and per-deck counts from
  Supabase
- schedules ratings with FSRS
- stores a local snapshot and durable review outbox so offline reviews are not
  lost
- shares the Health design system and auth shell
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

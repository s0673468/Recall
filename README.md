# Recall

Cross-platform Anki review app for the Health workspace.

## Role

- reads decks, due cards, new cards, recent reviews, and per-deck counts from
  Supabase
- schedules ratings with FSRS
- stores a local snapshot and durable review outbox so offline reviews are not
  lost
- shares the Health design system and auth shell

## Local commands

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --reporter=failures-only
flutter run -d chrome --dart-define-from-file=config/supabase.local.json
```

Use `config/supabase.local.example.json` for local bootstrapping only. Keep the
build input to `SUPABASE_URL` plus `SUPABASE_ANON_KEY`; user access still goes
through interactive auth and row-level security.

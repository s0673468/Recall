# Recall — agent instructions

<!-- shared-rules:v1 -->
Shared rules, skills and helper roles load on their own from this machine's
global instructions. This file holds only what is special about this project.
A shared safety or approval rule wins over this file; for project facts, this
file wins.
<!-- /shared-rules -->

## What this is

Recall is German's Android spaced-repetition review app (Flutter) with its own
Supabase project and FSRS scheduling engine, independent of Health data. Laptop
and web review use the separate Recall Hub repository. The Dart package name
stays `health_anki_flutter`; Health's shared UI and auth pieces are vendored
under `lib/vendored/`. The Anki collector that feeds Health stays in Health.

Platforms are **Android and web only**. iOS source, `IOS_SETUP.md` and the
built-in PWA (`WEB_SETUP.md`) are preserved history: do not build, test or
release from them. Preserved iOS tests are tagged `apple-mobile` and skipped.

## How to run and check it

`.flutter-version` is the one supported SDK; always go through `tool/flutterw`,
which checks it before every command.

```bash
./tool/bootstrap_flutter
./tool/flutterw pub get
./tool/flutterw analyze --no-pub
./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile
```

- Hosted CI (`.github/workflows/ci.yml`) is the full gate: analyze, four
  `flutter test` file shards, Android compile and release-policy checks, and the
  Python suites. Recall is public, so hosted checks cost no private minutes.
- Python tooling: `python3 -m unittest discover -s tool/tests -p 'test_*.py'`
  with the pinned Dart on `PATH`, plus the `tools/*/tests` suites CI lists.
- While iterating, `python3 tool/affected_tests.py --base origin/main` plans the
  smallest checks; add `--run` (portable lane) or `--lane android --run`. See
  `docs/testing.md`. Do not run `flutter clean` between ordinary edits.
- When you delete a test file, drop its entry from `tool/flutter_test_timings.json`.
- Speed and visual benchmarks run by hand, never in the default `flutter test`.

## What must not break

- **Supabase is the source of truth** for cards, notes, FSRS state,
  `review_log` and `user_settings`. The local snapshot is a disposable cache. The
  review, flag and preference outboxes are pending writes: never discard them,
  and never let them make the device authoritative.
- **Replay is idempotent** through `client_event_id` and the `apply_review` RPC.
  Scheduling is newest-review-wins; `reps`/`lapses` accumulate from server state.
  The SQL and Dart halves must stay in step (`review_replay.dart` and
  `scripts/supabase/verify/`).
- **Desktop Anki authors content; Recall owns scheduling.** Never create or edit
  card or article content from code changes. Content work goes through the
  `anki-revision` skill.
- **Study days reset at midnight America/Sao_Paulo**, whatever the device
  timezone (`lib/features/review/domain/study_day.dart`, also Recall Hub's
  contract). Unknown counts stay unknown and never show as zero.
- **Schema changes** follow `scripts/supabase/README.md`. Repository changes
  never apply SQL to production; a production apply and production smoke writes
  each need their own approval and a current backup.
- **Build input** is only `SUPABASE_URL` plus `SUPABASE_ANON_KEY`
  (`config/supabase.local.example.json` is for local bootstrapping). No
  service-role key or production data in the repository.
- **Diagnostics** (`operational-event/v2`) hold only fixed enums, timestamps,
  bounded numbers and an opaque run ID: no exception text, content,
  identifiers, paths, endpoints or credentials, and no network telemetry.
- **Tests guard what can lose or corrupt study data:** FSRS scheduling, due/new
  counts and daily limits; the outbox, sync, acknowledgements, undo and retries;
  local storage, snapshots and owner migrations; account isolation, sign-out and
  secure session storage; data honesty; CI gate wiring and public-runner
  boundaries (`test/ci_workflow_test.dart`). Do not add tests that pin layout
  geometry, pixel sizes, colours, copy, fonts, motion, haptics or benchmark
  timings.
- **Look and feel** (checked by looking, not by tests):
  - Layout: screens fit a 320–360 dp phone at 2x text scale without overflow or
    clipped titles. Wide web and unfolded Android show Study beside Reading.
    Native Android switches to the navigation rail at 600 dp. Settings and
    navigation stay reachable in short windows.
  - Theme: colours, type sizes and motion come from the theme tokens
    (`lib/theme/ui_tokens.dart` and the vendored tokens). Resting surfaces are
    flat. Headings and body share the system typeface. The quiet palette stays
    readable on its background.
  - Accessibility: buttons expose a semantic label and tap action with touch
    targets of at least 48 dp. Rating and undo announce live feedback. Sliders
    announce their real value. Charts give a short screen-reader summary.
  - Motion: respect reduced motion; haptics stay restrained; web feedback is a
    no-op.

## How it ships

Android is built and released from this repository on the existing package and
signing identity, preserving app data; a CI debug APK is not a signed in-place
update. Release signing, unsigned staging and device install steps are in
`ANDROID_SETUP.md`; install on a device only when asked. The tracked build
number must exceed the installed build. Web review ships from Recall Hub.

## Skills this project leans on

- Any screen change: `visual-acceptance`, against the look-and-feel list above
  and `docs/design-language.md` (Recall is the app family's visual reference).
- Android build to put on German's phone: `job-android-delivery`.
- Pull request ready or stuck: `git-pr-babysit`; failing CI shard:
  `git-ci-flake-failure-miner`.
- Project-local: `skills/anki-revision` for any card, flashcard, library or
  semantic-review content work.

## Where to look

- `README.md`: data ownership, replay, undo and diagnostics contracts.
- `ANDROID_SETUP.md`, `docs/testing.md`, `scripts/supabase/README.md`.
- `docs/design-language.md`, `docs/content-revalidation.md`,
  `docs/bot-guide-study.md`, `docs/card-golden-standard.md`.
- `tools/recall_sync/README.md`: the Mac-local Anki autosync runtime.

# AGENTS.md

Shared guide for Claude Code and Codex in Recall. `CLAUDE.md` points here.
Recall supports Android and web only; Apple sources stay frozen and untested.

## What tests are for

Tests guard the parts that can lose or corrupt study data:

- FSRS scheduling, due/new counts and daily limits;
- the review outbox, sync, acknowledgements, undo and retries;
- local storage, snapshots and owner migrations;
- account isolation, sign-out and secure session storage;
- data honesty: unknown counts stay unknown and never show as zero;
- CI gate wiring and public-runner boundaries in `test/ci_workflow_test.dart`.

Do not add tests that pin layout geometry, pixel sizes, colours, copy, fonts,
motion, haptics or benchmark timings. Check those by rendering the app and
looking at it (visual acceptance), then rely on this guide.

## Style and shape expectations

- **Layout.** Screens fit a 320–360 dp phone at 2x text scale without overflow or
  clipped titles. Wide web and unfolded Android show Study beside Reading.
  Native Android switches to the navigation rail at 600 dp. Settings and
  navigation stay reachable in short windows.
- **Theme.** Take colours, type sizes and motion from the theme tokens
  (`lib/theme/ui_tokens.dart` and the vendored tokens). Resting surfaces are flat.
  Headings and body use the same system typeface. Keep the quiet palette
  readable on its background.
- **Accessibility.** Buttons expose a semantic label and tap action, with touch
  targets of at least 48 dp. Rating and undo announce live feedback. Sliders
  announce their real value. Charts give a short screen-reader summary.
- **Motion and feedback.** Respect reduced motion. Haptics stay restrained, and
  web feedback is a no-op.
- **Benchmarks.** Speed and visual benchmarks run by hand. They do not belong in
  the default `flutter test` gate.

## Validation

- `./tool/flutterw analyze --no-pub` and `./tool/flutterw test --no-pub
  --exclude-tags apple-mobile` (CI runs four file shards).
- Python tooling: `python3 -m unittest discover -s tool/tests -p 'test_*.py'`
  with the pinned Dart on `PATH`, plus the `tools/*/tests` suites CI lists.
- When you delete a test file, drop its entry from
  `tool/flutter_test_timings.json`.

Follow `~/.config/agent-policy/git-golden-standard.md` for change tiers and PR
delivery. Never edit card or article content from code changes.

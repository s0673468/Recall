# Recall design language

Recall uses the quieter design approved in September 2026: a flat charcoal
canvas, warm text, soft yellow interaction cues, and generous space around the
current card. The shared Flutter UI carries that design to web, iOS, and Android.

## The benchmark

A learner should be able to identify the screen's purpose and next action in
one glance. Information stays available, but secondary controls do not compete
with the current task.

- Give each screen one clear point of emphasis. Use flat panels only for a
  distinct interaction group, such as the study card or automatic review.
- Use ruled lists and open sections for supporting information. Avoid nested
  panels, filled status pills, decorative icon boxes, and gradient washes.
- Use system typography, sentence case, and restrained heading weight. Let
  titles and descriptions wrap; never solve crowding by shrinking text.
- Reserve soft yellow for interaction and selection. Muted green, blue, and
  terracotta communicate status alongside a written label.
- Keep touch targets comfortable. On narrow screens or with larger text,
  move supporting controls onto another line instead of compressing them.

## Recall hierarchy

- **Study:** the current card is the focus. Queue and progress are quiet
  context; answer reveal and the four ratings remain the primary interaction.
- **Decks:** automatic review leads. Core decks use simple rows; optional
  curricula remain available in a disclosure and in search.
- **Stats:** retention leads. Activity, upcoming work, and concepts to reinforce
  are available without showing every detailed panel at once.
- **Read:** connected reading leads, followed by a searchable library. A primer
  presents its title, subject, and content without stacked badges and panels.
- **Settings:** scheduling controls remain directly available. Scheduler
  details and per-deck overrides expand on demand. Reminders and account
  actions use normal open sections.

## Palette and type

The canvas is `#181a1c`, panels are `#202325`, and rules use `#363a3d`.
Primary text is warm `#ebeae6`; secondary text is `#bec2c3` and muted text is
`#a0a6a9`. Recall's interaction accent is the soft yellow `#d4c18d`.

Headings and controls use the platform's system typeface. Emphasis comes from
size, weight, and spacing, rather than a separate display font or uppercase
labels. Body, secondary, and semantic text must retain at least 4.5:1 contrast
against each resting surface. Accent-filled controls use dark text.

## Platform contract

iOS and Android share the same product surface and information hierarchy.
Native conventions remain where they improve ergonomics: Cupertino tab chrome,
routes, action sheets, and time selection on iOS; Material navigation, the
adaptive rail, back behavior, and system integration on Android.

Launch surfaces use the charcoal canvas so neither platform flashes white
before Flutter paints. The redesign does not change card content, scheduling,
account boundaries, or offline synchronization.

## Implementation primitives

`lib/theme/ui_tokens.dart` owns Recall's palette, theme, and flat surface
factories. Geometry tokens remain shared with the vendored Health library;
Recall's visual tokens intentionally no longer mirror its palette or fonts.
Do not edit vendored assets to restore old parity.

`lib/core/widgets/recall_surfaces.dart` owns composition: the study/automatic
review panel, ruled metric strips, status text, and grouped rows.
`RecallPageHeader` supports a title with optional supporting text. Shared rows
allow optional icons and wrapping titles so each screen can remove redundant
chrome without inventing a separate component.

Motion is short, directional, and removed when Reduce Motion is enabled.
Study content remains independently scrollable. A card tap must not reveal
its answer, and visual changes must not alter FSRS scheduling behavior.

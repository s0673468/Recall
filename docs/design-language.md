# Recall design language

Recall is the reference implementation for the shared visual language used by
German's personal apps. Other products should feel like members of the same
family without copying Recall's yellow product accent or its study-specific
interactions.

## The benchmark

The interface should feel calm before it feels dense. A person should be able
to identify the screen's purpose, the most important state, and the next useful
action in one glance.

- Give each top-level screen at most one hero surface.
- Use bounded cards for real interaction groups, not as decoration around every
  block of information.
- Present repeated peer information in one ruled metric strip or grouped list.
- Keep the canvas, typography, spacing, radii, borders, and motion shared across
  the app family. The product accent is the intentional point of difference.
- Use yellow for Recall interaction and selection. Use semantic score colours
  for learning quality, success, warning, and failure.
- Keep resting surfaces flat. Shadows belong to overlays.

## Recall hierarchy

- **Study:** the current card is the hero. Queue counts are quiet context;
  revealing and rating remain the primary interaction.
- **Decks:** Automatic review is the hero. Core decks and optional curricula are
  separate supporting groups.
- **Stats:** true retention is the hero. Workload, activity, forecast, and weak
  concepts follow in decreasing order of importance.
- **Read:** today's connected reading is the hero. The searchable primer library
  is supporting content.
- **Settings:** scheduling is the leading control group. Reminders, per-deck
  limits, and account actions are normal bounded sections.

## Platform contract

iOS and Android share the same Flutter product surface and information
hierarchy. Platform conventions remain native where they improve ergonomics:
Cupertino tab chrome, routes, action sheets, and time selection on iOS;
Material navigation, the adaptive rail, back behavior, and system integration
on Android.

The native launch surfaces must use the graphite canvas so neither platform
flashes white before Flutter paints.

## Implementation primitives

The shared palette and type live in `lib/theme/ui_tokens.dart`. Recall-specific
composition lives in `lib/core/widgets/recall_surfaces.dart`. Screens should use
those primitives before adding screen-local decoration. New styling belongs in
the shared layer when two or more screens need the same visual role.

Motion is short, directional, and removed when Reduce Motion is enabled. Study
content remains independently scrollable, and visual changes must not make a
card tap reveal the answer or alter FSRS scheduling behavior.

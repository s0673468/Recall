# Recall visual acceptance — 2026-10-24

Synthetic fixtures only. No account, Supabase client, personal cards/articles,
credentials, or external services were used for this acceptance pass.

## Coverage

Flutter 3.47.1 widget screenshots at 360×800, 412×915, and 1280×800;
dark theme, text scale 1.3. Each viewport has 17 before/after pairs:

- Reading and “From your chats”; the independently scrolling Reading panel.
- Library browser, no search results, and empty library.
- Concept reader with a long title, body paragraphs, and inline mathematics.
- Settings top, scrolled reminders/account, and expanded per-deck override.
- Stats overview, expanded Activity/heatmap, empty, error, and loading.
- Reading empty, error/retry, and loading.

`before/` captures the original application source at `f485835` using the same
synthetic fixtures. `after/` contains the 51 checked golden baselines. Every PNG
was opened and visually inspected. PNG names start with the logical viewport
width and then the scene name. The 1280px Reading panel is 420px wide, isolated
from Study so this pass cannot alter its header or daily count.

The harness loads bundled text, Material icon, and package-qualified math fonts,
isolates each screen's page storage, disables transition animations, and repaints
text layers before capture. Normal test runs compare all 51 after PNGs exactly;
they do not regenerate baselines. Loading futures are held explicitly, then
completed; storage is an in-memory SharedPreferences fixture.

## Findings → fixes → files

| Issue | Fix | File under `lib/features/` |
| --- | --- | --- |
| Loading loses the reading screen's identity and gives no explanation | Keep the Read heading; add “Loading primers…” and a progress semantics label | `review/presentation/screens/read_screen.dart` |
| Empty reading promises a full library even when none exists | Show “No recent reading yet.” when the library is empty | `review/presentation/screens/read_screen.dart` |
| Chat rows repeat “From your chats” below an identical section heading | Remove the repeated row subtitle in that section; retain library metadata | `review/presentation/screens/read_screen.dart` |
| Phone reader gutters leave less room for long titles and scaled body text | Use the same 18dp phone gutter as the reading/library lists; retain desktop gutters | `review/presentation/screens/primer_screen.dart` |
| Reading panel refresh/back targets measure 40dp | Give both controls a minimum 48×48dp target | `review/presentation/widgets/desktop_reading_pane.dart` |
| Settings decrement/increment targets measure 40dp | Give steppers a minimum 48×48dp target | `settings/presentation/screens/settings_screen.dart` |
| Expanded deck override content floats toward the middle on desktop | Stretch disclosure children so names/controls align with section text | `settings/presentation/screens/settings_screen.dart` |
| Heatmap legend is tiny and sits inconsistently beside the grid | Increase labels from 10sp to 12sp, match grid swatches, and align to the available right edge | `review/presentation/widgets/review_heatmap.dart` |

The new `test/reading_visual_acceptance_test.dart` also asserts target dimensions,
reader gutters, deck-row alignment, chat heading uniqueness, loading copy and
semantics, empty copy, legend size/alignment, search clearing, and opening/closing
a primer in the panel. Existing tests were preserved.

## Acceptance limits and follow-up

The requested surfaces have no observed unintended clipping, overlaps, or
unreadable enabled text in these fixtures. A long focused search query scrolls
horizontally inside its field as expected. Scrolled screenshots intentionally
show partially visible rows at the viewport edge. Disabled reminder controls
use the existing disabled styling.

Remaining polish: Stats still uses spinner-only loading sections; named section
placeholders would make a slow load easier to understand. Its error sections
remain readable but rely on pull-to-refresh rather than an inline retry action.

This is Flutter layout/raster acceptance at phone and desktop dimensions, not an
installed Android device or Chromium execution. Native system chrome, browser
engine differences, real accounts, and delivery are outside this pass. The
legacy Flutter web client remains retired as documented; nothing was published.
No Study header, review controller, daily-count, or Apple-mobile source changed.

See `validation.txt` for the final commands and results. Git metadata remained
read-only; the runner owns the commit.

## Review correction: deterministic dates

The Activity baselines were captured on Saturday, October 24. Using the current
date changed the final heatmap column on Sunday without an application regression.
The golden fixture now uses local noon on October 24, 2026, and passes that clock
to every Stats screen. `StatsScreen` accepts an optional clock and uses its single
date for all chart transforms; the default remains the local system clock.

Reading also applies date windows to the shared fixtures. Its screen and embedded
desktop pane accept the same clock so freezing the fixtures cannot make recent
reading or chat rows age out of their screenshots later. These defaults also
remain the local system clock. No baselines or existing assertions changed.

`test/visual_acceptance_clock_test.dart` adds three regressions: Saturday-to-Sunday
heatmap and forecast changes while reusing cached data, plus recent reading/chat
expiry in both standalone and embedded Reading. All three fail with the original
system-clock reads restored and pass with the injectable clocks. The final full
suite compares all 51 existing after PNGs exactly. The three Activity PNGs were
opened again and inspected; their populated Saturday columns remain unchanged.

## Hosted CI fix: missing golden assets

At `d3ad2cb39a96`, the Git tree contained none of the 51 `after/` PNGs
referenced by the new visual test. All three viewport tests failed on their
first capture with “Could not be compared against non-existent file”. This
is a missing test-fixture failure introduced by this branch; the visual test
does not exist on its `origin/main` base.

Added the missing PNGs using the unchanged synthetic harness and pinned Flutter
3.47.1 on Linux: 17 scenes at each of 360×800, 412×915 and 1280×800.
Inspected contact sheets for all 51 captures, then compared every image without
`--update-goldens`. No application source, existing test or assertion changed.
See the hosted-CI fix results appended to `validation.txt`.

## PR #184 CI fix: daily reset text in Settings

The daily-count branch adds `StudyDay.resetDescription` below the new-card
limit, while these baselines predate that text. The unchanged visual test on
Flutter 3.47.1 reproduced CI's exact Settings differences: 28,972 pixels at
360px, 36,672 at 412px, and 30,067 at 1280px. This is a baseline mismatch with
the PR's intended UI change, rather than a timing, temporary-directory or umask
failure.

Regenerated all 51 captures with the existing synthetic harness. Only seven
Settings PNGs changed: the three initial views, all three scrolled views, and
the 412px expanded view. The first mismatch previously stopped each viewport
test before it could compare the later Settings captures. Visually inspected
all seven replacements; the reset explanation wraps without clipping and the
remaining controls retain their layout. Application source, test source and
pixel comparison strictness are unchanged.

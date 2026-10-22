# Recall scheduling and import hunt — 2026-10-21

Scope: FSRS inputs and outputs, review-log integrity and undo, the desktop
card importer and its dedup, and Stats counts. Prefs paging (#157) and study
session isolation / offline recovery (#158) were skipped as instructed. No
repository `AGENTS.md` exists; README was read first. Only invented fixtures,
temporary directories and in-memory fakes were used. No card or article
content was changed.

All six real findings were in the desktop importer,
`tools/anki_revision/import_to_supabase.py`, which had no tests. It is the only
writer that seeds FSRS state for cards Recall has not reviewed yet. Each fix
has a regression test in `tools/anki_revision/tests/test_import_to_supabase.py`.
Every new test failed against the importer it fixes and passes now. Findings
5 and 6 came from review of the first fix round.

## Fixed findings

1. **A card already reviewed in Recall could be reseeded with desktop
   scheduling.** The guard that protects reviewed cards (`cloud_seen`, `:296`)
   is built by `_fetch_all`. That function paged with `range()` offsets and no
   `ORDER BY`, and it stopped at the first page shorter than 1,000 rows.
   Without an order, PostgreSQL guarantees no row order, and a sequential scan
   returns rows in physical order. A review that lands while the importer is
   reading writes a new row version elsewhere, so the row at the page boundary
   is skipped. The skipped card then counts as unseen, and the importer
   overwrites its stability, difficulty, due date, state, reps, lapses and
   `last_review` with the desktop values. A server row cap below 1,000 also
   cut every read short; with more notes than the cap, the import stopped on a
   `KeyError`. The read now pages by key on `id`, in order, and stops only on
   an empty page (`:224`).
   Tests: `test_reviewed_cards_keep_recall_scheduling_while_the_app_studies`
   (`test_import_to_supabase.py:374`) is an end-to-end `run()` over 1,001
   reviewed cards, with one phone review between pages. Before the fix,
   `guid-1001` was reseeded. `test_reads_every_row_through_a_lower_server_cap`
   (`test_import_to_supabase.py:352`) covers the cap.

2. **Interday (re)learning cards were imported as due in 1970.** Anki stores a
   learning step of a day or more in the day-learn queue, with `due` as a day
   number, as it does for review cards. The importer always read type 1/3 `due`
   as epoch seconds. Day-learn due values are now converted from the collection
   creation date. This uses Anki's own rule: values above 1,000,000,000 are
   epoch seconds (`:206`). The rule needs no queue value, so it also works for
   suspended and buried cards.
   Test: `test_interday_learning_due_is_a_day_number` (`test_import_to_supabase.py:118`).

3. **Cards in a filtered deck took the filtered deck and a placeholder due
   date.** In a filtered deck, Anki keeps the home deck in `odid` and the real
   due date in `odue`, and puts a queue position (for example `-100000`) into
   `due`. Re-imports moved those notes into the filtered deck in Recall, so
   `Opt-in::` cards could enter the automatic stream and per-deck counts were
   wrong. Unseen cards were also seeded as due centuries ago. The importer now
   uses `odid`/`odue` when they are set (`:150`, `:152`).
   Test: `test_filtered_deck_card_keeps_its_home_deck_and_real_due`
   (`test_import_to_supabase.py:139`).

4. **Review cards without Anki's `lrt` field were seeded with no last review,
   which FSRS reads as fully forgotten.** Older Anki versions store FSRS memory
   state (`s`, `d`) without `lrt`. With `last_review = null`, the scheduler
   computes retrievability 0. A probe through `FsrsEngine` on a card with
   stability 20 that was due now showed Good scheduling 717 days out instead of
   62, and Easy 2,113 days instead of 147. The importer now falls back to the
   newest review in `revlog` that moved the memory state (`:162`, `:216`;
   finding 6 narrows which entries count). Unreviewed rows heal on the next import, because
   the importer reseeds unseen cards every run.
   Test: `test_missing_last_review_time_falls_back_to_rated_review_history`
   (`test_import_to_supabase.py:162`).

5. **A first phone review that landed during an import could still be
   overwritten.** Finding 1 made the `cloud_seen` read complete, but the seed
   write was a plain upsert. If a card's first Recall review committed after
   that read and before the write, the importer replaced the new stability,
   difficulty, due date, state, reps, lapses and `last_review` with desktop
   values. `cloud_seen` stayed true, so later imports never repaired it. The
   write now carries the guard itself, with no schema change (`:324`):
   cards the cloud does not have yet are inserted with `ON CONFLICT DO
   NOTHING` (`ignore_duplicates`, `:349`); existing unreviewed cards are
   reseeded by `UPDATE … WHERE cloud_seen = false` (`:353`). Both review
   paths set `cloud_seen` in the same statement that writes the scheduling,
   under the row lock (`apply_review` in
   `scripts/supabase/migrations/008_apply_review_missing_card.sql:139`, and
   `mergeReviewIntoCard` in `lib/features/review/data/review_replay.dart:133`).
   PostgreSQL rechecks the `cloud_seen` filter after that lock, so a review
   that commits first always wins. To keep this to one request per changed
   card, the importer now also reads the scheduling of unreviewed cards
   (`:300`) and only reseeds cards whose desktop values differ (`:253`).
   Tests: `test_review_landing_before_the_seed_write_is_not_overwritten`
   (`test_import_to_supabase.py:456`) commits a phone review just before the
   importer's first card write; before the fix every scheduling column was
   overwritten. `test_unreviewed_cards_still_follow_desktop_scheduling`
   (`:496`) checks that new and changed unreviewed cards still take desktop
   scheduling, that reviewed cards do not, and that a card whose values come
   back from PostgREST at float32 precision and with a `Z` timestamp is not
   rewritten.

6. **Filtered-deck practice became the FSRS timestamp.** The finding 4
   fallback took the newest revlog entry with `ease > 0`. Practice in a
   filtered deck with rescheduling off is logged as `type = 3` with
   `factor = 0` and a positive ease, but it leaves the memory state
   unchanged. A later practice entry therefore became `last_review`, so FSRS
   saw less elapsed time and scheduled the next interval too short. The
   fallback now skips the same entries Anki's FSRS skips: types 4 (manual)
   and 5 (rescheduled), and type 3 with factor 0 (`:162`).
   Test: `test_filtered_practice_without_rescheduling_is_not_the_last_review`
   (`test_import_to_supabase.py:192`).

### What the new rules still accept

No input is newly rejected. The only new failure is in `_fetch_all`: it raises
if the server ignores the `id > last` filter and returns a page that does not
advance. Before, such a server could repeat or skip rows without any error.
The rules above still accept:

- Learning `due` values above 1,000,000,000 as epoch seconds, as before (any
  timestamp after September 2001). Smaller values are day numbers.
- `odue` only when both `odid` and `odue` are non-zero. Other cards keep
  `did`/`due` exactly as before. A filtered deck still gets its own deck row.
- A stored `lrt` always wins. Cards with no qualifying review (new, or
  reviewed only through manual reschedules or no-reschedule filtered
  practice) keep `last_review = null`, as before.
- Type 3 entries with a non-zero `factor` still count as reviews. Older
  schedulers logged rescheduling filtered-deck reviews that way, and those
  did change the memory state.
- Import writes never reject a row. A card reviewed in Recall between the
  read and the write is skipped silently and reseeding stops for it, which is
  the existing `cloud_seen` contract. A cloud timestamp that this Python
  cannot parse counts as changed, which costs one extra guarded update.

## Checked and rejected

| Path checked | Evidence and disposition |
| --- | --- |
| FSRS fuzz, learning-step reconstruction, learning stability clamp | `lib/features/review/application/fsrs_engine.dart:77`, `:107`, `:139`. Previews equal the persisted rating, and steps rebuild from `due - last_review`. Existing scheduling tests cover these paths. No defect. |
| Desired retention from `fsrs_params` is not range-checked | `lib/features/review/data/models.dart:142`. Stored prefs (clamped at `lib/features/settings/domain/recall_prefs.dart:131`) override it on load. Both writers emit in-range values: the importer writes 0.9 (`import_to_supabase.py:124`) and the optimizer apply path is validated. No real out-of-range source found, so no new clamp was added. |
| Day boundaries and DST for the new-card budget and forecast | `lib/features/review/data/recall_api.dart:570` ends the day at the next local midnight. `lib/features/review/application/stats_service.dart:167` counts calendar days in UTC components. Existing DST tests pass. No defect. |
| Multi-device replay and log integrity | `lib/features/review/data/review_replay.dart:160`, `:164` and `scripts/supabase/migrations/008_apply_review_missing_card.sql:135` both apply newest-review-wins with counters accumulated from the server. `recall_api.dart:748` sends lapses as a delta. No defect. |
| Undo | `recall_api.dart:986`: remote undo fails closed. Local undo is the divergence already documented in README. Not a new defect. |
| Re-rating a card whose review is still queued | `lib/features/review/application/review_controller.dart:1021` removes cards with pending outbox reviews from every reloaded queue, so a stale snapshot is never scheduled twice. No defect. |
| Stats retention and streak | `stats_service.dart:236` uses the interval actually tested. `:379` counts streaks over the whole log. Legacy rows without `state_after` keep their documented over-count. No defect. |
| Importer: renamed decks, re-imports, deleted notes | A rename keeps the Anki deck id, so the upsert on `user_id,deck_id` (`import_to_supabase.py:282`) updates the name in place. Notes and cards are keyed on `user_id,guid`. Stale guids are soft-deleted (`:362`), and a returning guid is set back to `deleted: false` by the link upsert. No defect. |
| Importer: decks deleted on desktop stay in Recall | `:282` never marks a deck deleted. The deck is empty, so its counts read 0 (`deck_counts` filters deleted cards, `scripts/supabase/migrations/002_cards_suspended.sql:29`). This is cosmetic, and deleting decks would be a new behavior. Not changed. |
| Importer: notes with more than one card | `card_seed[guid]` (`:207`) assumes one card per note, which matches the repo's Basic-only collection (`anki_common.py`). Duplicate guids in one upsert fail loudly in PostgreSQL instead of writing anything. Not changed. |
| Importer: Recall undo of a card's first review | Undo restores `cloud_seen = false` with the pre-review state (`lib/features/review/data/recall_api.dart:764`), so the importer may reseed that card again. That matches the card being unreviewed in Recall. No defect. |

## Validation

The commands were run in the repo root with the pinned Flutter 3.47.1 that
`tool/flutterw` resolves.

| Exact command | Result |
| --- | --- |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_import_to_supabase.py'` on the original importer | Exit 1. All 5 new tests failed (`99 != 2`, a 1970 due date, `None` last review, a truncated read, and `guid-1001` reseeded with `3.0 != 41.0`). |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_import_to_supabase.py'` with the new tests on the first-round importer | Exit 1. All 3 new tests failed: the phone review's state was overwritten (`3.0 != 41.0`, `3 != 30`, `None` last review), the changed unreviewed card was rewritten by a plain upsert instead of a guarded update (`0 != 1`), and the cram entry won (`2025-07-11…` instead of `2025-07-06…`). |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | Exit 0. 23 passed. |
| `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | Exit 0. 35 passed. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0. 166 passed, 1 skipped. |
| `python3 -m unittest discover -s tools/recall_sync/tests` | 25 run, 1 error, identical on the original tree: `python-dotenv` from `tools/recall_sync/requirements.txt` is not installed locally, and installing it into a local venv was not approved. CI installs it. The failing test is `install_runtime`, which this change does not touch. |
| `./tool/flutterw analyze --no-pub` | Exit 0. No issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0. 1,231 passed and 2 skipped, before any change, after round one and on the final tree. No Dart code changed. |

The fake PostgREST models the guarantees the fix relies on: physical order
when no order is given, a moved row on update, and a server row cap. It does
not run PostgreSQL. Real collections were not opened.

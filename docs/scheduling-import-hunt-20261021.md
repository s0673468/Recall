# Recall scheduling and import hunt — 2026-10-21

Scope: FSRS inputs and outputs, review-log integrity and undo, the desktop
card importer and its dedup, and Stats counts. Prefs paging (#157) and study
session isolation / offline recovery (#158) were skipped as instructed. No
repository `AGENTS.md` exists; README was read first. Only invented fixtures,
temporary directories and in-memory fakes were used. No card or article
content was changed.

All four real findings were in the desktop importer,
`tools/anki_revision/import_to_supabase.py`, which had no tests. It is the only
writer that seeds FSRS state for cards Recall has not reviewed yet. Each fix
has a regression test in `tools/anki_revision/tests/test_import_to_supabase.py`.
All five new tests failed against the original importer and pass now.

## Fixed findings

1. **A card already reviewed in Recall could be reseeded with desktop
   scheduling.** The guard that protects reviewed cards (`cloud_seen`, `:287`)
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
   an empty page (`:213`).
   Tests: `test_reviewed_cards_keep_recall_scheduling_while_the_app_studies`
   (`test_import_to_supabase.py:335`) is an end-to-end `run()` over 1,001
   reviewed cards, with one phone review between pages. Before the fix,
   `guid-1001` was reseeded. `test_reads_every_row_through_a_lower_server_cap`
   (`test_import_to_supabase.py:313`) covers the cap.

2. **Interday (re)learning cards were imported as due in 1970.** Anki stores a
   learning step of a day or more in the day-learn queue, with `due` as a day
   number, as it does for review cards. The importer always read type 1/3 `due`
   as epoch seconds. Day-learn due values are now converted from the collection
   creation date. This uses Anki's own rule: values above 1,000,000,000 are
   epoch seconds (`:195`). The rule needs no queue value, so it also works for
   suspended and buried cards.
   Test: `test_interday_learning_due_is_a_day_number` (`test_import_to_supabase.py:114`).

3. **Cards in a filtered deck took the filtered deck and a placeholder due
   date.** In a filtered deck, Anki keeps the home deck in `odid` and the real
   due date in `odue`, and puts a queue position (for example `-100000`) into
   `due`. Re-imports moved those notes into the filtered deck in Recall, so
   `Opt-in::` cards could enter the automatic stream and per-deck counts were
   wrong. Unseen cards were also seeded as due centuries ago. The importer now
   uses `odid`/`odue` when they are set (`:145`, `:147`).
   Test: `test_filtered_deck_card_keeps_its_home_deck_and_real_due`
   (`test_import_to_supabase.py:135`).

4. **Review cards without Anki's `lrt` field were seeded with no last review,
   which FSRS reads as fully forgotten.** Older Anki versions store FSRS memory
   state (`s`, `d`) without `lrt`. With `last_review = null`, the scheduler
   computes retrievability 0. A probe through `FsrsEngine` on a card with
   stability 20 that was due now showed Good scheduling 717 days out instead of
   62, and Easy 2,113 days instead of 147. The importer now falls back to the
   newest rated review in `revlog` (`ease > 0`, so manual reschedules are
   ignored) (`:155`, `:205`). Unreviewed rows heal on the next import, because
   the importer reseeds unseen cards every run.
   Test: `test_missing_last_review_time_falls_back_to_rated_review_history`
   (`test_import_to_supabase.py:158`).

### What the new rules still accept

No input is newly rejected. The only new failure is in `_fetch_all`: it raises
if the server ignores the `id > last` filter and returns a page that does not
advance. Before, such a server could repeat or skip rows without any error.
The rules above still accept:

- Learning `due` values above 1,000,000,000 as epoch seconds, as before (any
  timestamp after September 2001). Smaller values are day numbers.
- `odue` only when both `odid` and `odue` are non-zero. Other cards keep
  `did`/`due` exactly as before. A filtered deck still gets its own deck row.
- A stored `lrt` always wins. Cards with no rated review (new, or reviewed
  only through manual reschedules) keep `last_review = null`, as before.

## Checked and rejected

| Path checked | Evidence and disposition |
| --- | --- |
| FSRS fuzz, learning-step reconstruction, learning stability clamp | `lib/features/review/application/fsrs_engine.dart:77`, `:107`, `:139`. Previews equal the persisted rating, and steps rebuild from `due - last_review`. Existing scheduling tests cover these paths. No defect. |
| Desired retention from `fsrs_params` is not range-checked | `lib/features/review/data/models.dart:142`. Stored prefs (clamped at `lib/features/settings/domain/recall_prefs.dart:131`) override it on load. Both writers emit in-range values: the importer writes 0.9 (`import_to_supabase.py:119`) and the optimizer apply path is validated. No real out-of-range source found, so no new clamp was added. |
| Day boundaries and DST for the new-card budget and forecast | `lib/features/review/data/recall_api.dart:570` ends the day at the next local midnight. `lib/features/review/application/stats_service.dart:167` counts calendar days in UTC components. Existing DST tests pass. No defect. |
| Multi-device replay and log integrity | `lib/features/review/data/review_replay.dart:160`, `:164` and `scripts/supabase/migrations/008_apply_review_missing_card.sql:135` both apply newest-review-wins with counters accumulated from the server. `recall_api.dart:748` sends lapses as a delta. No defect. |
| Undo | `recall_api.dart:986`: remote undo fails closed. Local undo is the divergence already documented in README. Not a new defect. |
| Re-rating a card whose review is still queued | `lib/features/review/application/review_controller.dart:1021` removes cards with pending outbox reviews from every reloaded queue, so a stale snapshot is never scheduled twice. No defect. |
| Stats retention and streak | `stats_service.dart:236` uses the interval actually tested. `:379` counts streaks over the whole log. Legacy rows without `state_after` keep their documented over-count. No defect. |
| Importer: renamed decks, re-imports, deleted notes | A rename keeps the Anki deck id, so the upsert on `user_id,deck_id` (`import_to_supabase.py:245`) updates the name in place. Notes and cards are keyed on `user_id,guid`. Stale guids are soft-deleted (`:306`), and a returning guid is set back to `deleted: false`. No defect. |
| Importer: decks deleted on desktop stay in Recall | `:245` never marks a deck deleted. The deck is empty, so its counts read 0 (`deck_counts` filters deleted cards, `scripts/supabase/migrations/002_cards_suspended.sql:29`). This is cosmetic, and deleting decks would be a new behavior. Not changed. |
| Importer: notes with more than one card | `card_seed[guid]` (`:196`) assumes one card per note, which matches the repo's Basic-only collection (`anki_common.py`). Duplicate guids in one upsert fail loudly in PostgreSQL instead of writing anything. Not changed. |
| Importer: a review landing between the guard read and the seed upsert | The upsert is not conditional on `cloud_seen`, so a review landing in the seconds between the read and the write can still be overwritten. Closing that gap needs a server-side conditional write (a schema/RPC change), which is out of scope. Recorded as a residual risk. |

## Validation

The commands were run in the repo root with the pinned Flutter 3.47.1 that
`tool/flutterw` resolves.

| Exact command | Result |
| --- | --- |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_import_to_supabase.py'` on the original importer | Exit 1. All 5 new tests failed (`99 != 2`, a 1970 due date, `None` last review, a truncated read, and `guid-1001` reseeded with `3.0 != 41.0`). |
| `python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'` | Exit 0. 20 passed. |
| `python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'` | Exit 0. 35 passed. |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0. 166 passed, 1 skipped. |
| `python3 -m unittest discover -s tools/recall_sync/tests` | 25 run, 1 error, identical on the original tree: `python-dotenv` from `tools/recall_sync/requirements.txt` is not installed locally, and installing it into a local venv was not approved. CI installs it. The failing test is `install_runtime`, which this change does not touch. |
| `./tool/flutterw analyze --no-pub` | Exit 0. No issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` | Exit 0. 1,231 passed and 2 skipped, both before any change and on the final tree. No Dart code changed. |

The fake PostgREST models the guarantees the fix relies on: physical order
when no order is given, a moved row on update, and a server row cap. It does
not run PostgreSQL. Real collections were not opened.

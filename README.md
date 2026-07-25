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

## Data ownership

**Recall's Supabase project is the source of truth for all review and
scheduling state.** Everything on the device is cache or an outbound write
buffer — never an authority.

- **Supabase = truth.** Cards, notes, per-card FSRS scheduling state
  (`stability`/`difficulty`/`due`/`state`/`reps`/`lapses`/`last_review`), the
  append-only `review_log`, and study preferences (`user_settings`) all live in
  Supabase, scoped per user by row-level security.
- **Device state = disposable cache.** The local snapshot (last-loaded decks +
  study queue, `recall_snapshot_v1`) and the mirrored study prefs
  (`recall_prefs_v1`) are pure cache: they paint instantly on a cold open and
  are **rebuildable and discardable**. Every successful server fetch replaces
  them wholesale; a fresh cloud read on load/foreground always wins over what
  was cached. Wiping local storage loses nothing but paint latency.
- **The outbox is a pending *write*, not a competing source of truth.** Reviews
  and card flags taken offline are appended to a durable, append-only outbox
  (`recall_outbox_v1` / `flag_outbox_v1`) and replayed to Supabase at the next
  launch/foreground. This is the one piece of device state that is **not**
  freely discardable — it holds user actions that have not yet reached the
  server, so sign-out is fail-closed on a non-empty outbox. It never makes the
  device authoritative: it only carries local actions *toward* the server, which
  remains truth once they land.
- **Conflicts resolve server-wins for anything the device only reads** (queue,
  counts, prefs on load). Replayed reviews are deduplicated server-side by a
  durable `client_event_id` so a retry can never double-apply or log twice.
- **Desktop Anki authors content; Recall (web/app) owns scheduling.** The
  desktop importer is the sole author of cards/notes and sets `suspended` /
  `deleted` one-way; Recall never creates or edits card content. Recall owns the
  *review/scheduling* half: it computes FSRS outcomes and writes the resulting
  scheduling state + review log back to Supabase.

### Multi-device review conflicts

Two devices can each rate the same card while offline and flush in either
order. Review replay reconciles that instead of letting the last flush win
(`lib/features/review/data/review_replay.dart`):

- **Scheduling is newest-review-wins.** Whichever review carries the later
  `last_review` owns `stability`/`difficulty`/`due`/`state`. A review that
  syncs late but *happened* earlier leaves those columns alone rather than
  dragging the card back to a superseded due date.
- **`reps`/`lapses` accumulate from server state**, never from the absolute
  values a device computed off its own snapshot. Both reviews really happened,
  so both are counted regardless of which one won the scheduling.
- **The write is compare-and-swap on `reps`.** Every applied review bumps
  `reps` by exactly one, so it serves as a version for *review* writes: the
  update only lands if the row still holds the value the merge was computed
  from, otherwise the replay re-reads and re-merges. A card that stays
  contended through four rounds defers — the review stays in the outbox —
  rather than landing a stale write.

  Note the limit: this detects concurrent **reviews**, not every writer. A
  path that changes scheduling without incrementing `reps` (undo, below) still
  passes the guard. Making it a true row version would need a dedicated
  version column, i.e. a schema migration.

#### Idempotency: the `apply_review` RPC

Replay goes through the `apply_review` Postgres function, which does both
writes — the `review_log` append and the `cards` merge — in **one
transaction**, keyed on `client_event_id`:

- the log insert is the idempotency anchor. `ON CONFLICT DO NOTHING` against
  `review_log_card_client_event_uidx` means a replay returns the existing row
  id and touches nothing else;
- the card merge only runs when that insert actually created a row, so it
  happens exactly once per `(card_id, client_event_id)` however often the
  outbox retries;
- `SELECT … FOR UPDATE` serialises concurrent replays, so no compare-and-swap
  or retry loop is needed on this path.

The function is `SECURITY INVOKER`, so the `auth.uid() = user_id` policies
still apply. It lives in the Health repo as
`scripts/supabase_migrate_recall_review_rpc.sql`, with a matching
`supabase_verify_…` script that exercises the policy inside a
rolled-back transaction, and a `supabase_rollback_…` script.

**The client-side path below is the fallback**, used only when the function
isn't deployed. It cannot be made fully idempotent from outside the database:
the merge recognises its own partial apply when the row already carries the
review's `last_review`, but that is a heuristic, and three cases fall outside
it — a review that *lost* the scheduling race wrote no `last_review`; another
device can overwrite `last_review` between our merge and our log append; and
two devices rating at the identical instant are indistinguishable from our own
partial apply, so that rep is dropped. All three are counter-only (`FsrsEngine`
never reads `reps`/`lapses`, so scheduling cannot be corrupted) and every event
is still logged, so the true count stays recoverable from `review_log`.

> Because the policy is now expressed twice — in SQL and in
> `review_replay.dart` — the two can drift. `supabase_verify_recall_review_rpc.sql`
> pins the SQL half against the same cases the Dart suite pins.

Replay stays idempotent through the `client_event_id` ledger. That id is
minted per install (`LocalReviewStore.newEventId`) from an install id, a
counter, and a random suffix: the outbox outlives a restart while in-memory
counters reset, so a purely clock-derived id could repeat after a clock
rollback and the server would discard a genuine review as a replay.

### Known divergences from strict server-wins

- **Study prefs write-through is last-write-wins** (`RecallPrefsController`,
  `lib/features/settings/application/recall_prefs_controller.dart`). The cloud
  row replaces the local mirror on load, but an offline prefs edit can overwrite
  a newer cloud value when it later writes through.
- **Undo restores its local pre-rating snapshot unconditionally**
  (`RecallApi.undoReview`). Undo is a single-level, session-scoped affordance
  for the rating you just made, so it deliberately writes the exact state it
  captured; a second device's review landing in that window would be overwritten.

Both are tolerable for a single user across a handful of devices, and are
recorded here so the doctrine matches real behavior.

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

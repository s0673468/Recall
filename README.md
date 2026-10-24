# Recall

Recall is an Android spaced-repetition review app with its own Supabase project
and FSRS engine, independent of Health data. Use
[Recall Hub](https://github.com/s0673468/recall-hub) for laptop and web review.
See the [web client pointer](web/README.md) for the existing client bookmark and
the legacy PWA retirement boundaries.

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
- keeps core decks in the automatic review stream while `Opt-in::` curricula
  remain available only through explicit deck selection
- schedules ratings with FSRS
- stores a local snapshot and durable review outbox so offline reviews are not
  lost
- reuses the vendored Health design system + auth shell
- runs as the installable Android review app

The supported clients are the Android app in this repository and Recall Hub for
laptop/web. The built-in Flutter PWA is retired from build and publication;
existing browser storage and unsent reviews remain preserved. Existing iOS source
and history are preserved, but iOS is not an active build, test or release target.
Client support does not establish current device, signed-in or deployed acceptance.

Recall is also the reference implementation for the shared app-family visual
language. See [`docs/design-language.md`](docs/design-language.md) for the
surface hierarchy, product-accent rules, and cross-platform contract.

## Data ownership

For read-only study questions in chat, use the
[Study guide for chat bots](docs/bot-guide-study.md), including schema meanings,
study metrics, SQL examples, and the connector-only grading boundary.

**Recall's Supabase project is the source of truth for all review and
scheduling state.** Everything on the device is cache or an outbound write
buffer — never an authority.

- **Supabase = truth.** Cards, notes, per-card FSRS scheduling state
  (`stability`/`difficulty`/`due`/`state`/`reps`/`lapses`/`last_review`), the
  append-only `review_log`, and study preferences (`user_settings`) all live in
  Supabase, scoped per user by row-level security.
- **Read-only device state = disposable cache.** The local snapshot
  (last-loaded decks + study queue, `recall_snapshot_v1`) is rebuildable and
  discardable. A successful server fetch replaces it wholesale.
- **The outbox is a pending *write*, not a competing source of truth.** Reviews
  and card flags taken offline are appended to a durable, append-only outbox
  (`recall_outbox_v1` / `flag_outbox_v1`) and replayed to Supabase at the next
  launch, foreground, or reconnect. Study preferences use one account-scoped,
  latest-value pending record by the same rule. Pending preferences replay
  before any cloud read, and clear only after the exact value reaches
  Supabase. These outbound writes are **not** freely discardable. They never
  make the device authoritative; they carry local actions toward the server,
  which remains truth once they land.
- **Conflicts resolve server-wins for anything the device only reads** (queue
  and counts). Replayed reviews are deduplicated server-side by a durable
  `client_event_id` so a retry can never double-apply or log twice. Preference
  writes are serialized per app process and latest-local-value wins until the
  pending record is accepted; subsequent cloud reads become authoritative.
- **Desktop Anki authors content; Recall (Android/Hub) owns scheduling.** The
  desktop importer is the sole author of cards/notes and sets `suspended` /
  `deleted` one-way; Recall never creates or edits card content. Recall owns the
  *review/scheduling* half: it computes FSRS outcomes and writes the resulting
  scheduling state + review log back to Supabase.

Material content edits use a timestamped note marker to request one near-term
validation review. Recall derives acknowledgement from a later successful row
in the existing append-only review log; it never resets FSRS history or adds a
second scheduling authority. See
[`docs/content-revalidation.md`](docs/content-revalidation.md) for the exact
authoring, offline, and convergence contract.

### Daily study count

The Study header's “N done” counts rated reviews, including Again, from the
shared `review_log` plus this device's durable unsynced review outbox. Events
are deduplicated by `client_event_id`; likes, dislikes and deletion flags do not
count. Undo of an unsent rating removes it from the count. Accepted review
identities are cached per account for offline restarts; an offline device cannot
see another device's reviews until it reconnects and refreshes.

Study days and daily new-card budgets reset at **midnight America/Sao_Paulo**
(currently UTC−03:00, or 03:00 UTC), regardless of the device timezone. The
shared rule lives in `lib/features/review/domain/study_day.dart` and is also the
contract for Recall Hub. There is no user-configured rollover hour or timezone.

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
still apply. Recall now owns its complete schema, ordered migrations,
read-only structural verification, rolled-back behavior check, and safe RPC
rollback under [`scripts/supabase/`](scripts/supabase/README.md).

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

### Known divergence from strict server-wins

- **Undo restores its local pre-rating snapshot unconditionally**
  (`RecallApi.undoReview`). Undo is a single-level, session-scoped affordance
  for the rating you just made, so it deliberately writes the exact state it
  captured; a second device's review landing in that window would be overwritten.

This is tolerable for a single user across a handful of devices and is recorded
here so the doctrine matches real behavior.

## Operational diagnostics

Recall records selected framework, background-sync, foreground-sync, and auth
failures as `operational-event/v2` envelopes under the isolated
`recall.operational_events.v2` preference. The ring retains at most 100 events
and 64 KiB.

The envelope accepts only fixed enums, timestamps, bounded numbers, and an
opaque run ID. It never stores exception text, stack traces, card or deck
content, user or device identifiers, paths, endpoints, or credentials.
Malformed or unavailable diagnostic storage is discarded without changing app
behavior.

On Android, each successfully committed ring is also mirrored byte for byte
inside the app's private, backup-excluded `noBackupFilesDir`. The native bridge
validates the same closed `operational-event/v2` JSON array, rejects payloads
above 64 KiB, and atomically replaces an owner-only `0600` file in an owner-only
`0700` directory. An invalid payload or failed write leaves the previous mirror
in place. The bridge never reads preferences, cards, decks, snapshots or review
outboxes, and every bridge failure is diagnostics-only. The mirror stays inside
the Android application sandbox. There is no network telemetry path.

## Local commands

The Mac-local Anki autosync uses a dedicated runtime worktree and a daily,
test-gated update job. See the [runtime installation and update instructions](tools/recall_sync/README.md).

Recall's application platforms are **Android and web**. Android is built,
tested and released from this repository; web review uses Recall Hub. iOS is
not maintained (see [Platforms](#platforms)).

For conservative checks selected from branch and working-tree changes, see
[Local test feedback](docs/testing.md). `python3 tool/affected_tests.py --base
origin/main` prints a plan without executing it; add `--run` for the portable lane
and `--lane android --run` for the native Android checks.

```bash
./tool/bootstrap_flutter
./tool/flutterw pub get
./tool/flutterw analyze --no-pub
./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile
./tool/flutterw build apk --debug --no-pub \
  --dart-define-from-file=config/supabase.local.json

# Repeatable rich-card parser benchmark (20,000 warmed operations per case).
./tool/flutterw pub run tool/recall_performance_benchmark.dart
```

`.flutter-version` is the single supported SDK version. `tool/flutterw` checks
the exact SDK before every supported command, so an older global Flutter cannot
silently produce a different build.

Use `config/supabase.local.example.json` for local bootstrapping only. Keep the
build input to `SUPABASE_URL` plus `SUPABASE_ANON_KEY`; user access still goes
through interactive auth and row-level security.

For a fresh Supabase project or a schema change, follow the exact apply,
verification, production-approval, and rollback boundaries in
[`scripts/supabase/README.md`](scripts/supabase/README.md). Repository changes
never apply SQL to production automatically.

## Platforms

- **Android** — maintained. [ANDROID_SETUP.md](ANDROID_SETUP.md) covers native
  checks, release signing, safe device installation, platform behavior and
  validation.
- **Web** — maintained through Recall Hub. Use the
  [Recall Hub source and setup guide](https://github.com/s0673468/recall-hub) and
  the [web client pointer](web/README.md).
- **iOS** — not maintained (Android + web only). Existing iOS source and
  [IOS_SETUP.md](IOS_SETUP.md) are preserved as history; do not build, test or
  release from them.

[WEB_SETUP.md](WEB_SETUP.md) describes the retired built-in PWA. The preserved
legacy guides describe historical clients; they are not current build or
delivery instructions.

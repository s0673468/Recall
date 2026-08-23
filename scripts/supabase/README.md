# Recall Supabase schema

This directory is the canonical, repository-owned schema for Recall’s separate
Supabase project. A fresh checkout no longer needs SQL from Health, a private
runtime directory, or an archived planning document.

The files describe the deployed contract used by the Flutter client, the Anki
importer, concept sync, flag tools, and review replay. They contain no project
URL, API key, service-role key, or production data. The established owner UUID
is schema data: mobile review/flag inserts omit `user_id`, and SQL-editor or
service-role verification has no `auth.uid()`, so those two tables preserve the
same owner default as the deployed single-user project and importer.

## Contract at a glance

| Object | Required contract | Writer |
| --- | --- | --- |
| `decks` | Anki deck id, name, soft deletion, per-user uniqueness | Anki importer |
| `notes` | content, tags, LaTeX metadata, deck link, soft deletion | Anki importer |
| `cards` | note link, FSRS state, `cloud_seen`, `deleted`, `suspended` | importer for identity/content state; Recall for scheduling |
| `review_log` | review result and timing, `client_event_id` ledger | `apply_review`; Recall undo may delete its one exact row |
| `user_settings` | JSON `fsrs_params` and `recall_prefs`, unique per user/key | importer seed and Recall |
| `note_flags` | four fixed reasons; open/resolved/dismissed lifecycle and resolution | Recall inserts; revision tooling resolves |
| `concept_nodes` | `node_id`, title, module, difficulty, update time | service-role concept sync |
| `concept_pages` | title, HTML primer, optional SVG figure, update time | service-role primer authoring |
| `deck_counts()` | due/new counts excluding deleted notes/cards and suspended cards | database RPC |
| `apply_review(...)` | atomic newest-review-wins merge with accumulated counters | database RPC |

User-owned tables have row-level security. `concept_nodes` and `concept_pages`
are global read-only reference data for clients; only service-role tooling writes
them. The service-role key remains outside Git.

## Exact apply order

Apply each file as one transaction, in this order:

1. [`migrations/000_base_schema.sql`](migrations/000_base_schema.sql)
2. [`migrations/001_note_flags.sql`](migrations/001_note_flags.sql)
3. [`migrations/002_cards_suspended.sql`](migrations/002_cards_suspended.sql)
4. [`migrations/003_concept_nodes.sql`](migrations/003_concept_nodes.sql)
5. [`migrations/004_concept_pages.sql`](migrations/004_concept_pages.sql)
6. [`migrations/005_review_event_idempotency.sql`](migrations/005_review_event_idempotency.sql)
7. [`migrations/006_apply_review_rpc.sql`](migrations/006_apply_review_rpc.sql)

All migrations are idempotent. Re-running them preserves rows. `000` uses
`CREATE TABLE IF NOT EXISTS`; it intentionally does not guess how to repair a
wrongly shaped existing table. The verification step reports drift instead.

### Fresh project

Create the isolated Recall Supabase project and configure Auth. Apply all seven
migrations before running the importer or releasing a client. Then create the
private runtime environment with only `SUPABASE_URL`,
`SUPABASE_SERVICE_KEY`, and `SUPABASE_USER_ID`; do not commit it.

Create or restore the established owner in `auth.users` before applying the
base migration, and keep the private runtime’s `SUPABASE_USER_ID` equal to the
checked-in importer/schema owner. The importer supplies `user_id` explicitly;
authenticated review and flag inserts rely on the table default while RLS still
requires that owner to equal `auth.uid()`.

### Existing production project

Repository changes do not authorize a production schema change. Applying any
migration is a separate high-risk operation that requires German’s explicit
approval, a current schema/data backup, and an operator who has resolved the
exact Recall project. Never paste SQL merely because it merged.

Before an approved apply:

1. Export a recoverable schema and data backup outside this repository.
2. Run [`verify/verify_schema.sql`](verify/verify_schema.sql) read-only. Record
   every reported gap; do not treat a failure as permission to apply everything.
3. Review only the migration files needed to close those gaps, in order.
4. Apply one file at a time and stop on the first error.

## Verification

After an approved apply, run:

1. [`verify/verify_schema.sql`](verify/verify_schema.sql). It reads PostgreSQL
   catalogs only and must return `VERIFY OK: Recall schema contract`.
2. [`verify/verify_apply_review.sql`](verify/verify_apply_review.sql). It tests
   new, duplicate, older, and timestamp-tie reviews. It deliberately ends with
   an exception so PostgreSQL rolls back every test write. Success is the
   exception text `VERIFY OK (rolled back; card … untouched)`.
3. The client smoke checks: authenticated deck/count reads, one review with
   exact log/card readback, undo, one flag, and concept/primer reads. Production
   smoke writes need their own explicit approval.

The behavioral verification locks one non-deleted card for milliseconds. A real
review of that card waits until the statement rolls back.

For repository-only drift checking, run:

```bash
./tool/flutterw test --no-pub test/supabase_schema_contract_test.dart \
  --reporter=failures-only
```

This static test proves that every Supabase table/RPC named by current Recall
code has a checked-in migration and that documentation points to real files. It
does not prove production state.

## Rollback policy

The safe rollback is intentionally asymmetric:

- Drop `apply_review` with
  [`rollback/006_drop_apply_review_rpc.sql`](rollback/006_drop_apply_review_rpc.sql).
  Current clients then use their documented client-side fallback.
- If uniqueness enforcement itself must be removed, run
  [`rollback/005_drop_event_unique_indexes.sql`](rollback/005_drop_event_unique_indexes.sql)
  second. It preserves both `client_event_id` columns and every event value.
- Do not drop columns or tables from migrations `000`–`004` as an incident
  response. Current clients require `cards.suspended`; flags and concepts carry
  user-authored data. Restore behavior first, retain the additive schema, and
  decide any destructive removal later from a verified backup with separate
  approval.

There is no automated “drop the whole Recall schema” script. On a disposable
fresh project, deleting the project is the clean rollback. On production, table
or column removal is destructive data work and outside these scripts.

## Provenance

| Canonical file | Source reviewed |
| --- | --- |
| `000_base_schema.sql` | archived `Anki-management/ANKI_WEB_PLAN.md`, section 3 |
| `001_note_flags.sql` | private runtime `migrations/001_note_flags.sql` |
| `002_cards_suspended.sql` | private runtime `migrations/002_cards_suspended.sql` |
| `003_concept_nodes.sql` | private runtime `migrations/003_concept_nodes.sql` |
| `004_concept_pages.sql` | archived primer migration plus the recorded deployed `figure_svg` field |
| `005_review_event_idempotency.sql` | Health `supabase_migrate_recall_idempotency.sql` |
| `006_apply_review_rpc.sql` | Health `supabase_migrate_recall_review_rpc.sql` |
| `verify_apply_review.sql` and RPC rollback | matching Health verification/rollback SQL |

The canonical copies remove machine/project identifiers, add explicit grants,
and make DDL replayable. They retain the deployed single-user owner default
because the app/RPC write shape and SQL-editor verification depend on it. The
data model and shipped client/RPC behavior remain the same.

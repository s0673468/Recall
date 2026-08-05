# Recall flag report

`flag_report.py` is a local, report-only authoring queue. It reads the fixed
live flag reasons from `note_flags`, resolves only the referenced note fronts
and deck names, and writes Markdown grouped by reason.

The tool is deliberately GET-only. It never inserts, updates, upserts, or
deletes cards or flags. The output contains only:

- the exact live reason (`wrong`, `confusing`, `too_long`, or `duplicate`);
- the flag's `guid`;
- a plain-text front prefix capped at 160 characters, with script/style/SVG
  content removed;
- the deck name; and
- the `flagged_at` UTC calendar date.

It does not output `card_id`, `device`, `client_event_id`, `user_id`, `status`,
the back of a card, or the raw Supabase response. The front prefix is still
intended for the owner's private local report; do not send the report to a
shared log or external service.

## Run

Use the same private runtime environment as `tools/recall_sync`:

```bash
python -m pip install -r tools/flag_report/requirements.txt
python tools/flag_report/flag_report.py > /tmp/recall-flag-authoring-queue.md
```

The script reads `SUPABASE_URL` and `SUPABASE_SERVICE_KEY`. It also loads an
optional private `tools/flag_report/.env`; that file is not part of the
repository.

Use `--output PATH` to write the completed report to a local file, or
`--dry-run` to print the required schema without contacting Supabase.

## Fail-closed preflight

Before reading flag rows, the tool sends one read-only `GET` with `limit=0`
for each required projection:

| Table | Required columns |
| --- | --- |
| `note_flags` | `card_id`, `guid`, `reason`, `flagged_at` |
| `notes` | `guid`, `front`, `deck_id` |
| `decks` | `deck_id`, `name` |

Missing tables/columns, malformed rows, a reason outside the fixed live set,
or missing note/deck context abort the run before any Markdown is written.
The tool does not infer a schema migration from a successful partial read.
The Recall checkout has no versioned Supabase DDL for `note_flags`; the
idempotency migration referenced by `IOS_SETUP.md` is owned outside this
checkout. Apply and verify the owning remote schema separately before treating
the runtime preflight as proof of production readiness.

## Tests

```bash
python -m unittest discover -s tools/flag_report/tests
```

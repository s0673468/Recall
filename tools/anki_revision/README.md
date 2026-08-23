# Recall-owned Anki revision tools

This directory is the versioned source for Recall's local Anki authoring and
one-way Supabase import seam. Production wrappers may invoke these files, but
must not maintain divergent copies or import code from an installed skill.

The canonical authoring standard is
[`docs/card-golden-standard.md`](../../docs/card-golden-standard.md). The thin
Codex skill is [`skills/anki-revision/SKILL.md`](../../skills/anki-revision/SKILL.md).
Install or verify the Codex copy with:

```bash
python3 skills/anki-revision/install.py
python3 skills/anki-revision/install.py --check
```

## Guarded content apply

Every future `edit` or `split` record declares `revision_kind` as `wording` or
`material`. A job containing material changes also declares a deterministic
manifest value such as `"revision_at": "20260812T120000Z"`. Material changes
replace older material markers with `content_revalidate::<revision_at>`;
wording-only edits leave any unresolved older marker untouched. New cards do
not need a marker because Recall already schedules them as unseen.

Dry run first:

```bash
python3 tools/anki_revision/anki_apply.py \
  --root /path/to/jobs-root --job reviewed-job --db /path/to/collection.anki2 \
  --tag semantic_review_20260812
```

This writes a new mode-0600 receipt under `jobs/reviewed-job/receipts/`. It
never overwrites an earlier receipt. After an independent exact backup exists:

```bash
python3 tools/anki_revision/anki_apply.py \
  --root /path/to/jobs-root --job reviewed-job --db /path/to/collection.anki2 \
  --tag semantic_review_20260812 --backup /path/to/before.anki2 \
  --dry-run-receipt /path/to/dry-run-receipt.json \
  --apply --confirmation APPLY_ANKI_CHANGESET
```

The apply locks the database, matches the receipt and exact logical backup,
checks stable note identities, preserves existing card rows, reads integrity
and counts back, and emits a separate immutable apply receipt. Verify it with:

```bash
python3 tools/anki_revision/verify_compiled.py \
  --db /path/to/collection.anki2 --job-dir /path/to/jobs/reviewed-job \
  --apply-receipt /path/to/apply-receipt.json --tag semantic_review_20260812
python3 tools/anki_revision/anki_validate.py --db /path/to/collection.anki2
python3 tools/anki_revision/anki_lint.py --db /path/to/collection.anki2
```

External `recall.card-handoff/v1` jobs additionally require
`--handoff-resolution`. The resolution uses schema
`recall.card-handoff-resolution/v1`; all three check results have status
`passed`, the golden-standard result carries the current file SHA-256, the
duplicate result carries `scope: full-catalog` plus a non-empty catalog digest,
and the node result names `assigned-existing` or `proposed-new`.

The semantic compiler enforces the same contract: every reviewed `edit` or
`split` declares `revision_kind`, and a material batch compiles only when given
one canonical `--revision-at`. For the already-applied 2026-08 pass, use the
read-only bootstrap below rather than reapplying content.

## Gardening and import

`anki_garden_score.py` emits `recall.garden-queue/v2`. Its `--limit` is bounded
to 20–40. It uses open flags first, then mature Again rate (`--min-reviews`),
Anki lapses, answer latency, material-change validation failures, and an
explicit volatile/recheck-due input. Network input is read-only; fixture files
can supply every optional signal for deterministic rehearsal.

`import_to_supabase.py` is the versioned importer. The existing runtime service
should become a thin launcher pinned to this path; its `.env`, launchd plist,
and machine-specific state remain outside Git. Run its dry run and exact cloud
readback before changing that runtime ownership.

For a semantic job already applied before `revision_kind` existed,
`bootstrap_revalidation.py` builds a read-only
`recall.revalidation-bootstrap/v1` proposal. It selects exact live `edit` or
`split` results with `score_before <= 3`, records stable GUID/note-type identity
and current tags, and never mutates the collection. Review and route that
artifact through a guarded tag writer; do not treat it as authorization by
itself. The repo-owned guarded writer is dry-run first and changes no content or
scheduling:

```bash
python3 tools/anki_revision/apply_revalidation_markers.py \
  --db /path/to/collection.anki2 --artifact /path/to/bootstrap.json
python3 tools/anki_revision/apply_revalidation_markers.py \
  --db /path/to/collection.anki2 --artifact /path/to/bootstrap.json \
  --backup /path/to/before.anki2 --dry-run-receipt /path/to/dry-run.json \
  --apply --confirmation APPLY_REVALIDATION_MARKERS
```

## Focused validation

```bash
python3 -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'
python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'
```

# Recall semantic review compiler

This tool validates a complete, concept-by-concept semantic review of Recall's
private learning corpus and compiles it into files accepted by the existing
guarded Anki authoring pipeline.

The compiler deliberately has no Anki, Supabase, authentication, or network
client. It cannot apply a change. Content is written by the separate guarded
`anki_apply.py` pipeline after its own backup and dry run. The narrowly scoped
`apply_tag_mutations.py` companion can then remove obsolete tags; it cannot
change fields, cards, scheduling, or decks.

## Inputs

- a concept manifest whose rows point to read-only concept bundles;
- one independently verified JSON review per concept;
- an `anki_prep.py` job containing the exact live-note manifest and batches; and
- optionally the METIS checkout, so edited primer HTML is checked by METIS's
  authoritative `scripts/check_primers.py` rules.

Every existing note id must appear exactly once and in its original concept
order. Kept cards must be byte-identical. Remaining cards must score 4 or 5.
The compiler rejects unresolved claims, missing clusters, malformed actions,
unknown decks or concept tags, clusters without an accuracy source, incomplete
placeholder-node moves, and output directories that already contain files.

## Compile

```bash
python3 tools/semantic_review/validate_and_compile.py \
  --concept-manifest /private/tmp/recall-semantic/concept_manifest.json \
  --reviews-dir /private/tmp/recall-semantic/verified \
  --prep-job-dir /private/tmp/recall-semantic/jobs/full-pass \
  --output-dir /private/tmp/recall-semantic/compiled \
  --metis-root /Users/germanchernukhin/Code/METIS
```

For an incremental subset that moves cards into clusters outside the subset,
pass the full catalog with `--known-concept-manifest`. The subset still needs
complete card coverage; the extra manifest supplies valid destination ids only.

Use `--allow-incomplete` only for a progress count. It writes no compiled
batches while any concept review is missing.

The output contains:

- `verified/batch_*.json` for the guarded Anki dry run;
- `manifest.json`, copied from the exact prepared Anki job so the compiled
  directory is a self-contained guarded apply input;
- `tag_mutations.json` for separately reviewed tag removals or node moves;
- `primer_changes.json` and `proposed_nodes.json` for METIS integration;
- `primer_files/*.html`, containing exact reviewed replacements and new-node
  primers ready for a mechanical copy into the METIS source tree;
- `figure_changes.json` and `figure_files/*.svg` for independently reviewed
  corrections to misleading diagrams or labels;
- `source_ledger.json` for private provenance; and
- `summary.json` for coverage and action counts.

## Apply reviewed tag removals

Run the content importer first so every replacement tag exists. Then dry-run
the mutation manifest against the same collection:

```bash
python3 tools/semantic_review/apply_tag_mutations.py \
  --db "/path/to/collection.anki2" \
  --mutations /private/tmp/recall-semantic/compiled/tag_mutations.json
```

The apply mode requires an existing non-empty backup plus a literal
confirmation. It locks the collection, compares every note with its reviewed
original state, proves the backup contains the exact pre-pass tags, changes tags
with compare-and-swap updates, runs SQLite's integrity check, and reads every
tag set back before committing:

```bash
python3 tools/semantic_review/apply_tag_mutations.py \
  --db "/path/to/collection.anki2" \
  --mutations /private/tmp/recall-semantic/compiled/tag_mutations.json \
  --backup "/path/to/pre-apply-backup.anki2" \
  --apply --confirmation APPLY_TAG_MUTATIONS
```

## Tests

```bash
python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'
```

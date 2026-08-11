# Recall semantic review compiler

This tool validates a complete, concept-by-concept semantic review of Recall's
private learning corpus and compiles it into files accepted by the existing
guarded Anki authoring pipeline.

It deliberately has no Anki, Supabase, authentication, or network client. It
cannot apply a change. The live collection remains writable only through the
separate `anki_apply.py` guard, after its own backup and dry run.

## Inputs

- a concept manifest whose rows point to read-only concept bundles;
- one independently verified JSON review per concept;
- an `anki_prep.py` job containing the exact live-note manifest and batches; and
- optionally the METIS checkout, so edited primer HTML is checked by METIS's
  authoritative `scripts/check_primers.py` rules.

Every existing note id must appear exactly once and in its original concept
order. Kept cards must be byte-identical. Remaining cards must score 4 or 5.
The compiler rejects unresolved claims, missing clusters, malformed actions,
unknown decks or concept tags, incomplete placeholder-node moves, and any
output directory that already contains files.

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
- `source_ledger.json` for private provenance; and
- `summary.json` for coverage and action counts.

## Tests

```bash
python3 -m unittest discover -s tools/semantic_review/tests -p 'test_*.py'
```

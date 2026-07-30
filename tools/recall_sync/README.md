# Recall concept-reference sync

This directory is the reviewed source for the Mac-local
`sync_concept_nodes.py` runtime.

The `concept_nodes` table is a union:

- METIS graph rows, which this job may update.
- Primer and deck-local rows, which this job does not own.

The sync is deliberately additive. Absence from METIS is not deletion
authority, so the job never removes a cloud row. This protects primer-specific
concepts such as `m00-cohens-kappa` and deck-local Portuguese nodes.

## Validate

```bash
python -m pip install -r tools/recall_sync/requirements.txt
python -m unittest discover -s tools/recall_sync/tests
```

## Deploy the reviewed source locally

After the change is merged, copy the exact reviewed script into the existing
private runtime and verify the two files match:

```bash
install -m 0644 tools/recall_sync/sync_concept_nodes.py \
  ~/Code/_runtime/recall-anki-sync/sync_concept_nodes.py
cmp tools/recall_sync/sync_concept_nodes.py \
  ~/Code/_runtime/recall-anki-sync/sync_concept_nodes.py
```

The runtime `.env` remains private and is never copied into this repository.

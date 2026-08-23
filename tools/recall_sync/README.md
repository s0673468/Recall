# Recall authoring sync runtime

This directory is the reviewed source for Recall's Mac-local Anki authoring
runtime. `run_autosync.py` owns the launchd execution path and calls the
repository-owned card importer plus `sync_concept_nodes.py`.

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

## Install the reviewed runtime

Keep the service-role values only in
`~/Code/_runtime/recall-anki-sync/.env`; `.env.example` documents the allowed
keys without embedding this project’s endpoint or public identifiers. The installer requires that file and
the existing private virtual environment, then writes an owner-only LaunchAgent
that executes the reviewed repository source directly:

```bash
python3 tools/recall_sync/install_runtime.py
launchctl bootout "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.german.recall-autosync.plist 2>/dev/null || true
python3 tools/recall_sync/install_runtime.py --apply
launchctl bootstrap "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.german.recall-autosync.plist
```

The first command is a no-write plist preview. `--apply` enforces mode `0700`
on the runtime directory and `0600` on the `.env`, stamp, lock, receipt log, and
LaunchAgent. It preserves the previous plain-text log as an owner-only
timestamped legacy file instead of deleting it.

The persistent log is `~/Library/Logs/recall-autosync.jsonl`. It contains only
closed `operational-event/v2` envelopes, never subprocess output. Same-directory
atomic replacement keeps at most 100 events and 64 KiB. Import failure does not
advance the source stamp. Concept sync remains additive; either child failure
keeps the source revision pending for the LaunchAgent's bounded 15-minute retry.
Each child process has a 20-minute timeout, and both the Anki collection and
METIS concept graph use nanosecond change tokens.

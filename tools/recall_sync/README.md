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
python -m unittest discover -s tools/anki_revision/tests -p 'test_*.py'
```

## Install the reviewed runtime

Keep the service-role values only in
`~/Code/_runtime/recall-anki-sync/.env`; `.env.example` documents the allowed
keys without embedding this project’s endpoint or public identifiers. Keep the
existing private virtual environment at the same location. Source belongs in the
dedicated **detached linked worktree** `~/Code/_runtime/recall-src`, separate from
developer checkouts and private runtime state. HQ prepares it once, from the
reviewed repository, if it does not already exist:

```bash
git fetch origin main
git worktree add --detach ~/Code/_runtime/recall-src origin/main
```

The installer defaults to that dedicated source path even when invoked from a
developer checkout. From the merged checkout, first bootstrap an existing older
runtime with the new updater. This must report `updated` or `current` before
installing the daily job, so its source includes the updater itself. If it reports
`busy`, retry after the active sync finishes:

```bash
~/Code/_runtime/recall-anki-sync/.venv/bin/python \
  tools/recall_sync/install_runtime.py --update
```

The installer requires the private environment and writes two owner-only
LaunchAgents: autosync and the daily source updater. Preview, then install both:

```bash
~/Code/_runtime/recall-anki-sync/.venv/bin/python \
  tools/recall_sync/install_runtime.py
launchctl bootout "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.german.recall-autosync.plist 2>/dev/null || true
launchctl bootout "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.german.recall-runtime-update.plist 2>/dev/null || true
~/Code/_runtime/recall-anki-sync/.venv/bin/python \
  tools/recall_sync/install_runtime.py --apply
launchctl bootstrap "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.german.recall-autosync.plist
launchctl bootstrap "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.german.recall-runtime-update.plist
```

The first command in this block is a no-write preview of both plists. `--apply`
enforces mode `0700` on the runtime directory and `0600` on the `.env`, stamp,
lock, receipt log, and LaunchAgents. It preserves the previous plain-text log as an owner-only
timestamped legacy file instead of deleting it.

## Automatic source updates

`com.german.recall-runtime-update` runs on load and every 24 hours. It shares
`.autosync.lock` with the sync job, so updates and sync never run concurrently;
a busy updater skips until its next launch. An already running sync always
finishes on its current source. The next autosync invocation uses updated source.
For an immediate check, run:

```bash
~/Code/_runtime/recall-anki-sync/.venv/bin/python \
  ~/Code/_runtime/recall-src/tools/recall_sync/install_runtime.py --update
```

The updater requires a clean, detached linked worktree, including no untracked
files. It fetches only `origin`'s `main` (no tags, submodules, pruning or checkout
hooks), refuses divergent or older main, and pins the candidate SHA. It archives
that exact commit into a temporary directory and runs both validation commands
above using the existing runtime Python, with `-I -B`. Tests receive a temporary
home and a minimal environment, without the private `.env`, inherited service
configuration or user home. Only tracked source enters this copy; tests must
continue to use synthetic fixtures and mocked services. Missing tests, test
failures/timeouts, copy/fetch failures or newly dirty source prevent checkout.
After both suites pass, it rechecks the original clean HEAD and uses
`git checkout --detach --no-overwrite-ignore <tested-sha>` without forcing.
Before touching live source, it durably writes an owner-only
`.runtime-update.json` recovery record beside the existing runtime lock. Failed
checkout restores the previous commit and removes files partially added by that
update. The recovery record is removed only after verifying a clean result.
Autosync checks for this record under the same lock and refuses to load private
configuration, read sync sources or execute children while recovery is pending.

After an interrupted update, the next `--update` restores the recorded previous
commit **before** checking dirtiness or fetching, and reports `recovered`. Run
`--update` again to attempt the new main. If disk space, a stale Git lock or
another error prevents rollback, the record stays and both jobs report
`runtime_update_recovery_required`; autosync stays paused. HQ must resolve the
underlying problem and rerun the updater from an intact merged checkout if the
runtime's updater itself was damaged. Never delete the recovery record to resume
sync against a partially written tree. Invalid records or a runtime moved outside
the recorded commits require HQ inspection without automatic source changes.

No branch or other checkout is moved. Git's shared `origin/main` tracking ref
and fetched objects can advance even if validation fails; the runtime HEAD
remains on its previous commit after successful rollback. Recovery resets only
the dedicated runtime's tracked source and index for the recorded update; it
never performs a general clean. `.env`, `.venv`, sync stamps and private source
files stay in their existing locations. The updater never reads cards or runs
an import. No dependency installation occurs during updates: a future dependency
change that the existing virtualenv cannot satisfy fails validation and requires
HQ maintenance.

The command reports `updated`, `current`, `recovered`, `busy`, or a closed refusal reason and
exits 1 on refusal. The same bounded canonical receipt log below records
`operation: update_runtime`, without Git or test output. Inspect it locally for
reasons such as `dirty_runtime`, `non_fast_forward`, `git_command_failed` or
`candidate_tests_failed`; fix the cause and rerun `--update`. Dirty or divergent
runtimes require HQ inspection; the updater never resets or cleans them.

## Sync receipts

The persistent log is `~/Library/Logs/recall-autosync.jsonl`. It contains only
closed `operational-event/v2` envelopes, never subprocess output. Same-directory
atomic replacement keeps at most 100 events and 64 KiB. Import failure does not
advance the source stamp. Concept sync remains additive; either child failure
keeps the source revision pending for the LaunchAgent's bounded 15-minute retry.
Each child process has a 20-minute timeout, and both the Anki collection and
METIS concept graph use nanosecond change tokens. A private
`METIS_CONCEPTS_YAML` override controls the runner, its change token, and the
LaunchAgent watch path.

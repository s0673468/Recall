# Recall personal FSRS optimizer

This is the report-only DIR-1a optimizer for Recall. It reads a user's
`review_log`, current `cards`, and effective FSRS settings from Supabase, fits
the official open-source `fsrs[optimizer]` package, and writes no cloud data.

The compatibility gate is intentionally strict. The installed Python package
must be `fsrs` 6.1.1, its 21-parameter FSRS-6 model must have the same bounds
as Recall's Dart `fsrs` 2.0.1 package, and the output must pass those bounds
before it can be reported as a candidate. The JSON output is exactly the
settings shape that Recall parses:

```json
{
  "parameters": [21 numbers],
  "desired_retention": 0.9
}
```

## Install

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/fsrs_optimize/requirements.txt
```

## Live, read-only run

The live path requires all three values in the process environment. The user
ID is required so a service key cannot accidentally fit another user's data.
The service key is never read from a repository config file and is never
printed.

```bash
SUPABASE_URL="https://<project>.supabase.co" \
SUPABASE_SERVICE_KEY="<service-role-key>" \
RECALL_USER_ID="<user-uuid>" \
.venv/bin/python tools/fsrs_optimize/optimize_fsrs.py \
  --report-output /private/tmp/recall-fsrs-report.txt \
  --json-output /private/tmp/recall-fsrs-params.json
```

The command reads all pages of the user's review history and card rows. It
holds out the last 20% of reviews in chronological order, evaluates package
defaults, the current settings, and the fitted parameters on that holdout,
and only writes the JSON candidate when the fit has lower holdout log-loss
than the current configuration. A refused recommendation still produces the
human report and exits non-zero; it does not write the JSON candidate.
The tool also refuses histories whose 800-review training portion contains
fewer than 512 elapsed observations, because the upstream optimizer otherwise
returns package defaults without fitting.

Every Supabase request made by this tool is an HTTP `GET`. There is no apply
flag or write client.

## Fixture mode and tests

Fixture mode is network-free and uses the same parser, split, replay, metrics,
and output code as a live run:

```bash
.venv/bin/python tools/fsrs_optimize/optimize_fsrs.py \
  --fixture tools/fsrs_optimize/tests/fixtures/report_fixture.json \
  --report-output /private/tmp/fixture-report.txt \
  --json-output /private/tmp/fixture-params.json
```

Run the tool tests with:

```bash
.venv/bin/python -m unittest discover -s tools/fsrs_optimize/tests
```

Fixture and report files contain only synthetic identifiers, timestamps,
ratings, counts, and parameters. Do not place a service key or card content in
fixtures or output.

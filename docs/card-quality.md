# Card quality, phase 1

This is a local, report-only tool under `tools/card_quality`. It uses Python 3's
standard library, CPU only, with no package installation, network client, hosted
model, credentials, or changes to cards, flags, review history or scheduling.
Phase 1 uses invented decks exclusively. Real-data execution is reserved for HQ
on ger-z later; implementing `--real-data` does not authorize running it now.

## What it learns

The model predicts **problem feedback versus like feedback**. `quality_score`
is **1 minus the calibrated problem probability**, so **lower means more likely
to need revision**. It is conditional on feedback-labelled cards, not a validated
probability of quality across the entire collection. Flags are self-selected;
calibration on synthetic decks cannot establish calibration on German's cards.

Open `like` is the positive quality label. Open `dislike`, `delete`, `wrong`,
`confusing`, `too_long`, and `duplicate` are negative quality labels, counted by
reason in the aggregate training report. Multiple problem reasons count as one
training card. Conflicting like/problem feedback is excluded from training and
still protected as liked during gardening. Resolved/dismissed flags are excluded:
they can describe an older version of the content. Unlabelled cards are scored
but never silently treated as disliked. Deleted cards/notes are omitted.

The fixed predictors are visible front/back word and character counts, cloze
count, list/table/math/image presence, front/back character ratio, words per
sentence and characters per word (language-neutral readability proxies), and
maximum token-set Jaccard similarity to another card in the same deck. Here
“siblings” means deck peers; singleton decks have similarity zero. HTML attributes,
image paths and script/style text do not become vocabulary features. Similarity
uses transient token sets in memory, never saved text, token hashes or embeddings.
An inverted index avoids comparisons with peers sharing no tokens, but very
similar large decks can still require quadratic comparisons in phase 1.

Behaviour predictors are current Recall FSRS difficulty/stability, lapses,
Again fraction and median answer seconds, with explicit missing-value indicators.
Flag reasons, card/deck IDs and text vocabulary are **not predictors**.
All supplied review rows are aggregated; exports must contain deduplicated review
history. Unknown history is distinguished from observed zero. The phase 1 model
uses class-balanced L2 logistic regression, training-only standardization and
clipping at six standard deviations. The optimizer is deterministic full-batch
gradient descent with fixed settings; there is no stochastic training seed to tune.

Probability calibration is unweighted Platt scaling of predictions made with
whole training decks held out. This corrects the class-balanced fit toward the
observed feedback prevalence. Evaluation holds out one entire deck at a time;
inside each outer fold, calibration holds out only the remaining training decks.
The outer test deck is never used for fitting, scaling or calibration. The final
model is fit on all labelled cards and calibrated from their out-of-deck
predictions. At least three labelled decks are required, and every training
partition must contain both classes and at least four cards; otherwise training
refuses rather than reporting a misleading random card split.

The training report contains aggregate class/reason counts, per-fold counts
(without deck identities), Brier score, log loss, ten-bin expected calibration
error, ROC AUC and balanced accuracy. A training-prevalence baseline is evaluated
on the same held-out decks. Inspect calibration error and baseline comparisons
before allowing these scores to influence a real queue. Single-class test folds
have null AUC; the combined held-out evaluation still reports AUC.

`forget_score` is a separate bounded **heuristic**, not a learned or calibrated
FSRS recall probability. It combines smoothed Again fraction `(again+1)/(n+4)`
(weight .40), lapse/repetition fraction (.25), difficulty/10 (.20), and
`1/(1+stability/7)` (.15), renormalizing available evidence. Unknown/unreviewed
history returns .25 when no evidence exists. It does not extrapolate time since
last review or replace FSRS due scheduling.

`explain` converts the largest standardized coefficients into fixed plain
sentences such as “Liked cards tend to have shorter answers (an association,
not a cause).” These describe associations with the like class, including
behaviour associations, rather than causal rewrite instructions. A flat model
reports that no shared traits were learned.

## Run phase 1 with synthetic decks

Run from the repository root. Outputs go into an owner-only directory; files are
atomically replaced with mode `0600`. Existing output directories must be owned
by the current user with mode `0700`; symlink outputs/ancestors are refused.
The examples keep all artifacts inside this checkout.

```sh
python3 -m tools.card_quality synthetic --out .tools/card-quality-private/synthetic.json --seed 17
python3 -m tools.card_quality train --synthetic --input .tools/card-quality-private/synthetic.json --out .tools/card-quality-private/model.json
python3 -m tools.card_quality score --synthetic --input .tools/card-quality-private/synthetic.json --model .tools/card-quality-private/model.json --out .tools/card-quality-private/scores.json
python3 -m tools.card_quality explain --model .tools/card-quality-private/model.json
```

Use `.csv` instead of `.json` for the score output to select CSV. Each score row
has exactly `card_id`, `quality_score`, `forget_score`, and `top_reasons`.
Reasons use a fixed vocabulary of numeric feature names plus `liked_keep_style`.
The protection marker reveals that the card is liked; other per-card flag reasons,
deck names, GUIDs, question text, answers, review rows, article text, paths,
timestamps and free-text comments are not exported. The synthetic
fixture command is the sole command that writes content, and only invented content.

Do not commit runtime exports, models, score files or ID maps. `.tools/` is
already ignored. Keep lasting code and synthetic generators in version control.

## Phase 2 handoff for HQ on ger-z

Do not run these commands as part of phase 1. HQ supplies a private, consistent,
single-account offline JSON snapshot from the same tables used by `anki_flags`,
`flag_report` and `fsrs_optimize`: `notes`, `cards`, `review_log`, `note_flags`.
This tool does not fetch those tables, read environment files, use device caches,
or obtain credentials. It refuses to open sources until the caller selects
`--synthetic` or explicit `--real-data`. Synthetic mode also requires a marked
fixture. This gate prevents accidental live reads, not deliberate mislabelling.

The export envelope is:

```json
{
  "schema": "recall.card-quality-source/v1",
  "notes": [{"guid": "synthetic-guid", "deck_id": 1, "front": "Invented?", "back": "Example."}],
  "cards": [{"id": 1, "guid": "synthetic-guid", "difficulty": 3, "stability": 15, "reps": 10, "lapses": 1}],
  "review_log": [{"card_id": 1, "guid": "synthetic-guid", "rating": 3, "elapsed_ms": 2000}],
  "note_flags": [{"card_id": 1, "guid": "synthetic-guid", "reason": "like", "status": "open"}]
}
```

That is an illustrative synthetic row, insufficient for training. Optional
`deleted` fields on notes/cards are respected; `elapsed_ms` and scheduling fields
may be null/absent. Every review/flag must link to both the exported card ID and
its GUID, including older resolved flags. Include the referenced cards/notes or
filter orphan rows when preparing a consistent snapshot. If `user_id` fields
are supplied, mixed-account exports are rejected. No IDs or malformed source
values are interpolated into diagnostics. The source may contain other fields;
none are written back or copied into artifacts.

Optionally provide a **local Anki snapshot**, matching the authoring source read
by existing revision tools. The adapter opens SQLite with `mode=ro` and projects
only `notes.id,guid,flds`; first/second fields provide front/back, matching the
existing importer. Recall export fields remain the authority for behaviour and
labels. No Anki scheduling values or revlog are substituted for cloud state.
Use consistent snapshots: there is no live collection default and no lock bypass.

Once HQ has prepared those files privately, the future local run is:

```sh
python3 -m tools.card_quality train --real-data --input .tools/card-quality-private/recall-export.json --out .tools/card-quality-private/model.json
python3 -m tools.card_quality score --real-data --input .tools/card-quality-private/recall-export.json --anki-db .tools/card-quality-private/collection.anki2 --model .tools/card-quality-private/model.json --out .tools/card-quality-private/scores.json --garden-map-out .tools/card-quality-private/card-map.json
python3 -m tools.card_quality explain --model .tools/card-quality-private/model.json --out .tools/card-quality-private/traits.txt
```

`--garden-map-out` needs `--anki-db` and writes only cloud card IDs paired with
local note IDs. Cloud card IDs are generated independently of local Anki card
and note IDs; never assume they match. Regenerate scores and the map together
from the same snapshot. Output paths must differ from every input and each other.
The model file contains numeric aggregate fit/calibration parameters and metrics,
never training examples or identities. Treat all learned artifacts as private:
aggregate traits and weights are still derived from personal feedback.

## Weekly gardening

The existing queue is unchanged without the two optional arguments below:

```sh
python3 tools/anki_revision/anki_garden_score.py --no-cloud --db .tools/card-quality-private/collection.anki2 --out .tools/card-quality-private/garden.json --quality-scores .tools/card-quality-private/scores.json --quality-card-map .tools/card-quality-private/card-map.json
```

The gardening priority gains `.25*(1-quality_score) + .20*forget_score`, using
the largest combined signal when a note maps to multiple cards. Priorities
remain capped at one, corrective flags stay first and queue limits stay 20–40.
Liked notes are omitted from model-assisted revision, including any sibling
marked `liked_keep_style` or an open like supplied through `--flags-file`.
With cloud input enabled and no flags file, gardening also fetches current open
likes, protecting cards liked after the scores were generated. For an offline
run, supply current flags through `--flags-file` or regenerate the scores.
No like is resolved or dismissed. The scorer's explanations guide suggested
rewrites of **other** cards alongside the existing card standard. They never
justify automatically editing liked cards or changing scheduling.

Both optional files are required together. Missing/malformed files, duplicate
score IDs, out-of-range/nonfinite scores, unmapped IDs and maps referencing absent
local notes are refused. Unscored notes retain their existing evidence ranking.
Scores carry no freshness timestamp; regenerate them for each weekly snapshot.
The ordinary garden command's existing cloud behaviour is unchanged; use
`--no-cloud` for an offline run as shown above.

## Validation

All new fixtures are generated, never copied from personal data. Tests cover
planted signals, imbalance/calibration metrics, deterministic fitting, held-out
calibration partitions, missing history, all flag reasons, conflicting labels,
read-only SQLite, private artifact permissions, safe errors, source preservation,
no network calls, and optional gardening/like protection.
`test/card_quality_tool_test.dart` also runs the synthetic Python suite in the
existing Flutter CI test lane, following the flag-report wrapper pattern.

```sh
python3 -m unittest discover -s tools/card_quality/tests
python3 -m unittest discover -s tools/anki_revision/tests
python3 -m unittest discover -s tools/flag_report/tests
python3 -m unittest discover -s tool/tests
./tool/flutterw analyze --no-pub
```

The repository's complete gate remains the maintained CI lanes described in
[testing.md](testing.md); no iOS build or test is part of this feature.

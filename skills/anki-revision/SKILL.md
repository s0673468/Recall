---
name: anki-revision
description: >-
  Safely inspect, revise, fact-check, author, deduplicate, gap-fill, or garden
  German's Recall and Anki learning materials. Use for Anki cards, flashcards,
  Recall library content, card flags, and compiled semantic-review changes. Do
  not use for ordinary Recall app features or scheduling-only analysis.
---

<!-- Repo-canonical skill. Install under ~/.codex/skills/anki-revision. -->

# Anki revision

Recall owns the workflow and quality standard. For ordinary learning work,
use one checkout of the verified current merged Recall revision. Prefer
`/Users/germanchernukhin/Code/Recall` when it has that source; if it holds
different active work, use an isolated checkout without switching or rewriting
the active branch. When the user explicitly asks to develop or review unmerged
skill or tool behavior, use the selected development revision instead.

Read `docs/card-golden-standard.md` and use the tools under `tools/anki_revision`
from that same checkout. The applier hashes the standard in its own checkout.
Reading a different revision can invalidate the handoff evidence.

Before proposing mutations, distinguish semantic revision, technical repair,
and read-only review. Check the current content owner, accepted wording, and
any active content freeze against the requested scope. Technical-only repairs
must preserve card fronts, backs, and primer text exactly. A quality concern
outside that scope is a finding, not permission to rewrite accepted content.

Reason freely about card quality and current knowledge. Keep the mutation seam
deterministic: changes are reviewed JSON artifacts; agents do not edit the live
database directly. Large or factual passes need source provenance and a fresh
independent semantic verification. Tiny wording corrections do not require a
second agent merely to satisfy ceremony.

Before a write, close Anki and create an independent backup. Run the content
apply as a dry run, inspect its immutable receipt, then supply that exact
receipt, backup, and literal confirmation to the apply command. Validate the
compiled contract and lint the resulting collection afterward. Never bypass a
failed guard. The applier preserves existing card rows, including scheduling
and decks.

Classify changed facts as `revision_kind: material` and provide one job-level
UTC `revision_at`; wording-only changes use `revision_kind: wording`. Material
edits receive a timestamped `content_revalidate::*` marker so Recall can surface
one near-term validation review without resetting FSRS history.

External card proposals carrying `recall.card-handoff/v1` require a consumer
resolution proving the current golden standard, full-catalog duplicate search,
and concept-node ownership as either assigned to an existing node or proposed
as a new node before dry run or apply.

Before suggesting improvements, read the liked cards from open `like` flags
(`anki_flags.py list --reason like --json`). Read their full fronts and backs
by the returned nids/guids; the truncated list previews alone are insufficient.
Summarize their shared length, structure, wording, cloze style, examples, and formatting. Apply
those observed preferences to suggested edits of other cards, alongside the
quality standard. If there are no likes or no shared traits, say so instead of
inventing preferences. Mention which preferences were applied in the weekly
summary. Likes are standing preferences, never revision work items: never
rewrite a liked card only because it is flagged, and never resolve or dismiss
likes during the weekly pass. The learner removes likes in Recall.

For routine gardening, build a bounded 20–40 card queue. Open corrective learner flags
come first; mature Again rate, lapses, slow answers, failed post-edit validation,
and due `volatile` claims supply the remaining evidence. Resolve flags only
after exact local and cloud readback. Keep the existing dislike/delete flow.

Optional local card-quality assistance: follow `docs/card-quality.md`. Phase 1
uses synthetic decks only; HQ runs a separately authorized offline `--real-data`
pass on ger-z later. Never read real card content, review rows or flags merely
to develop or test the model. When a private scores file and its matching cloud
card ID/local note ID map exist, pass `--quality-scores` and `--quality-card-map`
to `anki_garden_score.py`. Low quality and high forget scores increase priority;
corrective flags remain first and liked cards never enter the model-assisted
revise queue. Without these files, keep the existing routine. Regenerate both
from the same weekly snapshot; do not assume cloud and Anki IDs match.

Use `python3 -m tools.card_quality explain --model PRIVATE_MODEL.json` for the
content-free global summary. Shared liked-card shape traits guide suggested
rewrites of other cards alongside the golden standard; behaviour associations
are evidence, not wording instructions. State which traits informed the rewrite,
and report no shared traits when the model has none. Never copy raw training
examples into reports, rewrite liked cards because of model scores, or resolve
likes. This optional analysis does not authorize content or scheduling writes.

The versioned importer is the production source. Installed skill copies contain
this skill file only; they must not become a second source of executable tools.

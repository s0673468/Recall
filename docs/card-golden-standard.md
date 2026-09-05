# Recall learning-material golden standard

Version: 2026-08-22. Applies to every flashcard and concept primer in Recall.

## What belongs in Recall

Keep knowledge that is useful across future decisions, frequently applied, a prerequisite for
other learning, easily confused, or expensive to reconstruct. Prefer durable mechanisms and
decision rules over trivia. A volatile fact belongs only when its current value is itself useful;
otherwise turn it into the stable principle behind the fact.

Understand before memorizing. A card must make sense from its answer and its concept primer. Do
not preserve a polished sentence whose meaning is unclear, false, or unsupported.

## Review streams

Machine learning, mathematics, and the other core technical decks belong to the normal automatic
review stream. Optional curricula belong under the `Opt-in::` deck root and enter a session only
when the learner opens that deck explicitly. Use names such as `Opt-in::Portuguese` and
`Opt-in::Russian Revolution`; do not suspend these cards or alter their FSRS history. The existing
top-level `Portuguese` and `Experimental::` decks are treated as opt-in for compatibility until
they are renamed.

## Flashcard rules

1. **One gradeable retrieval target.** The learner must know what a correct answer contains. A
   multi-step calculation may remain one card when the steps form one skill; a bundle of
   independent facts must split.
2. **Necessary context, no answer leakage.** State the domain, assumptions, units, convention,
   direction, or paper when needed to make the answer unique. Do not include a synonym or formula
   fragment that gives the answer away.
3. **Minimum sufficient answer.** Lead with the exact answer. Add at most one short explanation,
   boundary, or memory hook when it prevents a misconception. A primer, not a card back, owns the
   longer explanation.
4. **Readable in one pass.** Explain what is happening and why in familiar, concrete language
   before relying on technical labels. Keep the exact term, formula, or qualification, but do not
   make the learner unpack compressed academic prose or defensive caveat stacks. A strong default
   is: direct answer, one plain-language mechanism or example, then one short boundary only when it
   changes what counts as correct. Move further nuance to the primer or another card.
5. **Show the mathematical source.** When a useful formula governs the mechanism being described,
   include it on the card back after the plain-language explanation as an ungraded extra. Define
   non-obvious symbols and keep assumptions, signs, units, and domains that control correctness.
   The formula should reveal where the intuition comes from, not become a second retrieval target;
   split the card if both explanation and derivation need to be graded.
6. **Successful effort.** Require genuine recall, derivation, completion, discrimination, or
   sentence production. Difficulty is useful only when the target is understandable and the cue
   makes successful retrieval plausible; obscurity is not a virtue.
7. **Truth with scope.** Label definitions, theorems, heuristics, empirical findings, and design
   conventions accurately. Preserve qualifications. Mathematical cards state dimensions,
   assumptions, signs, and domains whenever omitting them changes the result.
8. **Currentness and provenance.** Classify each claim as durable, time-bound, or disputed.
   Fact-check time-bound and disputed claims against current primary sources. Keep source URLs and
   access dates in the review manifest. Put a source/date on the study face only when the answer
   depends on that source or date. Add `volatile` to claims requiring later re-checks.
9. **Transfer, not paraphrase count.** A useful cluster may contain a definition, mechanism,
   calculation/application, contrast, failure mode, and decision rule. Each must require a
   distinct retrieval. More than about eight cards is a review trigger, not an automatic deletion
   rule.
10. **Control interference.** For confusable ideas, make the cues distinguish them and add one
   contrast card when that contrast is useful. Avoid several fronts that can all be answered with
   the same vague paragraph.
11. **Preserve learning continuity.** Keep a good card unchanged. Edit before deleting. Delete only
   an exact semantic duplicate, a false/obsolete low-value claim, or an orphaned fragment whose
   useful target is covered elsewhere. Record the reason and replacement coverage.
12. **Language rule.** Use English except for the Portuguese language being produced or analyzed.
    Portuguese cards should elicit a sentence or contextual choice in Brazilian Portuguese, name
    material accepted alternatives, and avoid bare conjugation-table recitation.
13. **Formatting.** Use `<br>` for breaks and sparing `<b>` emphasis. Use MathJax delimiters
    `\( ... \)` and `\[ ... \]` for formulas. No inline styles, emoji, nested wrappers, or
    decorative prose.
14. **Self-contained grading.** The back must let the learner decide whether the attempted answer
    was correct. Do not rely on an unstated external diagram, prior card order, or an answer such as
    “it depends” without the controlling condition.

## Cluster and gap-fill rules

- Review every existing card before adding to its cluster.
- Map the cluster's prerequisite, core mechanism, application, contrast, limitation, and adjacent
  decision before declaring a gap.
- Add only high-value missing retrievals. Do not add a synonym, a second wording of the same fact,
  or a detail better looked up.
- Prefer a small connected cluster over an isolated card. New adjacent concepts require their own
  node and primer rather than a catch-all `node::none` tag.
- A cluster is complete enough when a learner can define the idea, use it in the common case, and
  avoid its most consequential confusion. It need not exhaust the field.

## Primer rules

A primer is the explanatory layer behind the cards. It must be accurate, current, readable without
other cards, and aligned with the cluster's vocabulary and conventions.

- Keep 100-280 words, 2-5 paragraphs, no paragraph over 100 words, no more than one list and three
  list items, and only the markup accepted by `scripts/check_primers.py`.
- Give a compact mental model, one concrete example or derivation, and the most important boundary
  or confusion. Do not turn the primer into a glossary or repeat every card answer.
- A current paper or product-specific claim needs a date and primary-source provenance in the
  review manifest. Stable concepts should not be cluttered with citations on the reading face.
- Figures must agree with the text's notation and claim. A decorative or misleading figure is worse
  than no figure.

## Review score

Score each card from 1 to 5 before and after:

- **5:** valuable, unambiguous, atomic/gradeable, accurate with necessary scope, understandable on
  the first reading, efficient, and distinct within its cluster.
- **4:** safe, useful, and readable; only minor wording or optional-context improvements remain.
- **3:** learnable but ambiguous, bundled, redundant, weakly scoped, or weakly sourced.
- **2:** materially confusing, obsolete, misleading, or testing the wrong target.
- **1:** false, ungradeable, exact duplicate, or not worth retaining.

Only cards scoring 4 or 5 may remain after the pass. A `keep` record must preserve the original
front and back exactly.

Preserve an accepted voice when it meets these rules. For example, an accepted answer such as
"A cache keeps a nearby copy so repeat reads can be faster" stays unchanged during a tag repair.
Replacing it with "Caching optimizes data-access performance" would be an unrequested style
change, not part of the technical repair. An authorized semantic pass may revise wording when
it fixes a concrete clarity or correctness problem.

## Revision and gardening rules

- Classify every edit or split as `revision_kind: wording` or `material`. Material means the
  expected retrieval, factual content, scope, assumption, answer boundary, or grading decision
  changed. Spelling, grammar, markup, and equally precise phrasing are wording changes.
- Publish one canonical UTC `revision_at` for a batch containing material changes. Previously
  studied material edits receive the corresponding `content_revalidate::<timestamp>` marker;
  wording edits do not advance it. A later Hard, Good, or Easy review acknowledges that revision.
  Again leaves it pending. Never reset FSRS history to force a rereview.
- Garden in bounded batches of 20-40 cards. Open learner flags come first. Fill the rest only from
  mature evidence: a high Again rate after at least five reviews, repeated lapses, consistently
  slow answers, failed post-edit validation, or a due `volatile` source check.
- A gardening signal is a reason to inspect, not permission to rewrite. Apply the same truth,
  deduplication, concept-ownership, source, backup, and exact-readback gates as a large semantic
  pass.

## Evidence basis

- SuperMemo, “Twenty rules of formulating knowledge”: minimum information, unambiguous wording,
  interference control, examples, and understanding before memorization.
  https://www.supermemo.com/en/blog/twenty-rules-of-formulating-knowledge
- Butler (2010), repeated testing and transfer. DOI: 10.1037/a0019902.
- Butler et al. (2017), retrieval with varied examples and transfer. PMID: 29265856.
- Higham et al. (2023), spaced retrieval, corrective feedback, and successive relearning.
  https://discovery.ucl.ac.uk/10177745/1/Spaced%20Retrieval%20Practice%20Can%20Restudying%20Trump%20Retrieval.pdf

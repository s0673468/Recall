# Recall learning-material golden standard

Version: 2026-11-12 (v3: punchy cards, read-once reading pages). Applies to every flashcard and
concept primer (reading page) in Recall.

## Division of labour

The card is one question and one short answer the learner can say out loud; it is what gets graded.
The reading page for the card's concept holds everything else: the derivation, the formula
breakdown, the graph, the comparison with neighbours, more examples. A card never has to carry the
whole idea, because the page is one tap away ("Read explanation"). When in doubt, move it off the
card and onto the page.

The learner's own review history (2,508 reviews on 521 cards, November 2026) sets the budgets below:

| Back length | Again rate | Median answer time |
| --- | ---: | ---: |
| under 15 words | 4-6% | 19-24 s |
| 15-25 words | 7% | 28 s |
| 25-40 words | 14% | 31 s |
| 40+ words | 10-25% | 42-50 s |

Long answers fail about twice as often and take about twice as long. The most-failed cards were bare
formulas with no meaning attached, step lists and two-part answers.

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
3. **Answer first, one anchor, then stop.** The back opens with the graded answer on its own
   line: a phrase, a short sentence or one formula, at most about 12 words, in bold (a formula
   answer stands alone on the line and is not wrapped in bold). After a line break comes at most
   one anchor line of about 20 words that makes the answer stick. Pick the anchor by card type:
   formula: its meaning in words, a tiny worked number or a sanity check; definition: one concrete
   example; mechanism: the cause chain ("because ... so ..."); contrast: the neighbour in one
   clause; pitfall: the classic way it goes wrong. One anchor only, and never the same hook on two
   sibling cards.
4. **Budget and voice.** Front: one plain question of about 20 words that names the topic first and
   asks for exactly one thing (a scenario may take 30). Back: about 35 words, hard ceiling 45, not
   counting formula symbols. Going over needs a reason: the maths is the target, or the card is a
   worked calculation. Write spoken English, the way one explains at a whiteboard: no em-dash
   chains, bracket stacks, telegraphic noun piles or hedge stacks. A condition appears only when it
   changes what counts as correct. A list is the exception: at most three short parallel items, and
   only when the list is the target.
5. **Formulas live on the reading page.** A card carries a formula only when the formula is the
   graded answer; its anchor then says what the formula means. The derivation, the symbol-by-symbol
   breakdown and the worked example belong to the reading page, in the cards' exact notation.
   Split the card if both the meaning and the formula need to be graded.
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
11. **Preserve learning continuity.** Keep a good card unchanged. A card the learner has studied
   and answers reliably keeps its front and its answer; fix it only when it is wrong, ambiguous or
   far over budget, then change the back and leave the front. Edit before deleting. Delete only
   an exact semantic duplicate, a false/obsolete low-value claim, or an orphaned fragment whose
   useful target is covered elsewhere. Record the reason and replacement coverage.
12. **Language rule.** Use English except for the Portuguese language being produced or analyzed.
    Portuguese cards should elicit a sentence or contextual choice in Brazilian Portuguese, name
    material accepted alternatives, and avoid bare conjugation-table recitation.
13. **Formatting.** Use `<br>` for breaks; bold only the answer line; `<i>` for short labels such
    as `<i>e.g.</i>`. Use MathJax delimiters `\( ... \)` and `\[ ... \]` for formulas. No inline
    styles, emoji, nested wrappers, or decorative prose. The apps show a back whose first line is
    entirely bold (or one maths expression) and is followed by a top-level `<br>` as answer plus
    secondary anchor line, so keep that shape exact.
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
  node and primer rather than a catch-all `node::none` tag. A card distilled from a chat reading
  page carries `page::<page id>`, which links its "Read explanation" to that page.
- Basics first: a cluster with advanced cards but no plain "what is it" card gets the basic one.
  Together the cards should let the learner say what the idea is, why it matters or how it works,
  use its main formula or number, tell it from its nearest neighbour, and know how it fails.
  That is usually three to seven cards.
- A cluster is complete enough when a learner can define the idea, use it in the common case, and
  avoid its most consequential confusion. It need not exhaust the field.

## Primer rules

A primer is the explanatory layer behind the cards. It must be accurate, current, readable without
other cards, and aligned with the cluster's vocabulary and conventions.

- Read once, find things fast. A page is a sequence of sections, each opened by a paragraph that
  starts with a bold label and a full stop (`<b>In short.</b> ...`). Use the labels the topic needs,
  in this order, each at most once: `In short.` (required), `Picture it.`, `How it works.`,
  `The formula.`, `Worked example.`, `Compare.`, `Watch out.` (required), `Where you'll meet it.`
  The apps turn these labels into section headings and a contents row, so the spelling is exact.
- Keep 350-650 words (up to 900 for a concept with 15 or more cards): more room per idea, not more
  ideas. One idea per paragraph, two or three sentences, at most about 70 words. Every term is
  defined the first time it appears. At most two lists (the formula's symbol list and Compare), six
  items each, and only the markup the reading-page linter accepts.
- `The formula.` shows display maths, one list item per symbol, then one sentence on what it says.
  `Worked example.` runs real numbers all the way through, then a second example that looks
  different when that helps the idea transfer. `Compare.` names two to four confusable neighbours
  and says what differs and when to pick which.
- Card and page agree. Every card answer in the cluster can be found on the page in the same
  notation and vocabulary, and anything trimmed off a card lands on the page. Sibling pages do not
  reuse one analogy.
- Figures teach: one top figure plus up to three inline (a real curve where a function matters, a
  side-by-side for a comparison, the worked number drawn to scale), each placed after the paragraph
  it illustrates.
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

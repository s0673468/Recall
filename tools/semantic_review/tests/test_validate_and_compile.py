from __future__ import annotations

import ast
import json
import sys
import tempfile
import unittest
from pathlib import Path


TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from validate_and_compile import ReviewError, compile_reviews  # noqa: E402


class SemanticReviewCompilerTest(unittest.TestCase):
    def test_compiler_imports_no_network_or_database_client(self) -> None:
        source_path = TOOL_ROOT / "validate_and_compile.py"
        tree = ast.parse(source_path.read_text(encoding="utf-8"))
        imported_roots = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported_roots.update(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported_roots.add(node.module.split(".", 1)[0])

        self.assertTrue(
            imported_roots.isdisjoint(
                {"http", "requests", "sqlite3", "supabase", "urllib"}
            ),
            imported_roots,
        )

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.concepts = self.root / "concepts"
        self.reviews = self.root / "reviews"
        self.job = self.root / "job"
        self.compiled = self.root / "compiled"
        for path in (self.concepts, self.reviews, self.job / "in"):
            path.mkdir(parents=True)

        self.bundle = {
            "node_id": "concept-a",
            "title": "Concept A",
            "decks": ["ML"],
            "card_count": 1,
            "cards": [
                {
                    "nid": 101,
                    "deck": "ML",
                    "front": "Original front?",
                    "back": "Original back.",
                    "tags": ["ml", "node::concept-a"],
                }
            ],
            "primer_path": None,
            "primer_html": None,
        }
        bundle_path = self.concepts / "concept-a.json"
        bundle_path.write_text(json.dumps(self.bundle), encoding="utf-8")
        self.concept_manifest = self.root / "concept_manifest.json"
        self.concept_manifest.write_text(
            json.dumps(
                [
                    {
                        "node_id": "concept-a",
                        "path": str(bundle_path),
                        "card_count": 1,
                        "has_primer": False,
                        "decks": ["ML"],
                    }
                ]
            ),
            encoding="utf-8",
        )
        (self.job / "manifest.json").write_text(
            json.dumps({"mode": "revise", "batches": ["batch_001"], "nids": [101]}),
            encoding="utf-8",
        )
        (self.job / "in" / "batch_001.json").write_text(
            json.dumps({"batch_id": "batch_001", "deck": "ML", "cards": self.bundle["cards"]}),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_review(self, **overrides: object) -> None:
        review = {
            "node_id": "concept-a",
            "summary": "Already meets the standard.",
            "sources": [
                {
                    "title": "Authoritative concept A reference",
                    "url": "https://example.invalid/concept-a",
                    "published_or_updated": "2026-01-01",
                    "accessed": "2026-08-11",
                    "supports": ["The reviewed definition of concept A"],
                }
            ],
            "card_changes": [
                {
                    "nid": 101,
                    "action": "keep",
                    "rationale": "Atomic and accurate.",
                    "score_before": 5,
                    "score_after": 5,
                    "cards": [
                        {
                            "front": "Original front?",
                            "back": "Original back.",
                            "tags_add": [],
                            "tags_remove": [],
                        }
                    ],
                }
            ],
            "new_cards": [],
            "node_moves": [],
            "primer": {"action": "missing", "path": None, "rationale": "No primer.", "html": None},
            "proposed_nodes": [],
            "unresolved": [],
        }
        review.update(overrides)
        (self.reviews / "concept-a.json").write_text(json.dumps(review), encoding="utf-8")

    def compile(self) -> dict[str, object]:
        return compile_reviews(
            concept_manifest_path=self.concept_manifest,
            reviews_dir=self.reviews,
            prep_job_dir=self.job,
            output_dir=self.compiled,
            require_complete=True,
        )

    def test_compiles_exact_keep_into_existing_anki_batch(self) -> None:
        self.write_review()

        summary = self.compile()

        self.assertEqual(summary["existing_cards"], 1)
        self.assertEqual(summary["kept"], 1)
        compiled = json.loads(
            (self.compiled / "verified" / "batch_001.json").read_text(encoding="utf-8")
        )
        compiled_manifest = json.loads(
            (self.compiled / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(compiled[0]["nid"], 101)
        self.assertEqual(compiled[0]["action"], "keep")
        self.assertEqual(compiled[0]["cards"][0]["front"], "Original front?")
        self.assertEqual(compiled_manifest["nids"], [101])

    def test_rejects_keep_that_changes_content(self) -> None:
        self.write_review()
        path = self.reviews / "concept-a.json"
        review = json.loads(path.read_text(encoding="utf-8"))
        review["card_changes"][0]["cards"][0]["back"] = "Silently changed."
        path.write_text(json.dumps(review), encoding="utf-8")

        with self.assertRaisesRegex(ReviewError, "keep must preserve front and back"):
            self.compile()

    def test_rejects_missing_card_coverage(self) -> None:
        self.write_review(card_changes=[])

        with self.assertRaisesRegex(ReviewError, "card coverage mismatch"):
            self.compile()

    def test_rejects_post_review_score_below_four(self) -> None:
        self.write_review()
        path = self.reviews / "concept-a.json"
        review = json.loads(path.read_text(encoding="utf-8"))
        review["card_changes"][0]["score_after"] = 3
        path.write_text(json.dumps(review), encoding="utf-8")

        with self.assertRaisesRegex(ReviewError, "score_after must be 4 or 5"):
            self.compile()

    def test_rejects_cluster_without_accuracy_provenance(self) -> None:
        self.write_review(sources=[])

        with self.assertRaisesRegex(ReviewError, "at least one accuracy source"):
            self.compile()

    def test_incomplete_mode_reports_missing_cluster_without_writing_batches(self) -> None:
        summary = compile_reviews(
            concept_manifest_path=self.concept_manifest,
            reviews_dir=self.reviews,
            prep_job_dir=self.job,
            output_dir=self.compiled,
            require_complete=False,
        )

        self.assertEqual(summary["missing_clusters"], ["concept-a"])
        self.assertFalse((self.compiled / "verified").exists())

    def test_compiles_tag_removal_into_separate_mutation_manifest(self) -> None:
        self.write_review()
        path = self.reviews / "concept-a.json"
        review = json.loads(path.read_text(encoding="utf-8"))
        review["card_changes"][0]["action"] = "edit"
        review["card_changes"][0]["rationale"] = "Retag after semantic review."
        review["card_changes"][0]["cards"][0]["tags_add"] = ["volatile"]
        review["card_changes"][0]["cards"][0]["tags_remove"] = ["legacy"]
        path.write_text(json.dumps(review), encoding="utf-8")

        summary = self.compile()

        self.assertEqual(summary["tag_mutations"], 1)
        mutations = json.loads(
            (self.compiled / "tag_mutations.json").read_text(encoding="utf-8")
        )
        self.assertEqual(mutations[0]["nid"], 101)
        self.assertEqual(mutations[0]["add"], ["volatile"])
        self.assertEqual(mutations[0]["remove"], ["legacy"])

    def test_compiles_new_gap_card_with_real_concept_tag(self) -> None:
        self.write_review(
            new_cards=[
                {
                    "action": "add",
                    "deck": "ML",
                    "rationale": "Adds the missing application retrieval.",
                    "cards": [
                        {
                            "front": "Apply concept A?",
                            "back": "Application answer.",
                            "tags_add": ["ml", "node::concept-a"],
                        }
                    ],
                }
            ]
        )

        summary = self.compile()

        self.assertEqual(summary["new_card_records"], 1)
        additions = json.loads(
            (self.compiled / "verified" / "batch_additions.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(additions[0]["action"], "add")
        self.assertIsNone(additions[0]["nid"])

    def test_split_children_inherit_original_tags(self) -> None:
        self.write_review(
            card_changes=[
                {
                    "nid": 101,
                    "action": "split",
                    "rationale": "Two independent retrievals were bundled.",
                    "score_before": 3,
                    "score_after": 4,
                    "cards": [
                        {
                            "front": "First atomic front?",
                            "back": "First atomic back.",
                            "tags_add": [],
                            "tags_remove": [],
                        },
                        {
                            "front": "Second atomic front?",
                            "back": "Second atomic back.",
                            "tags_add": [],
                            "tags_remove": [],
                        },
                    ],
                }
            ]
        )

        self.compile()

        compiled = json.loads(
            (self.compiled / "verified" / "batch_001.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(compiled[0]["cards"][0]["tags_add"], [])
        self.assertEqual(
            compiled[0]["cards"][1]["tags_add"],
            ["ml", "node::concept-a"],
        )

    def test_rejects_unrecorded_concept_tag_change(self) -> None:
        self.write_review()
        path = self.reviews / "concept-a.json"
        review = json.loads(path.read_text(encoding="utf-8"))
        review["card_changes"][0]["action"] = "edit"
        review["card_changes"][0]["cards"][0]["tags_add"] = ["node::other"]
        path.write_text(json.dumps(review), encoding="utf-8")

        with self.assertRaisesRegex(ReviewError, "requires a node_moves record"):
            self.compile()

    def test_rejects_tag_removal_from_a_brand_new_card(self) -> None:
        self.write_review(
            new_cards=[
                {
                    "action": "add",
                    "deck": "ML",
                    "rationale": "Adds an application.",
                    "cards": [
                        {
                            "front": "Apply concept A?",
                            "back": "Application answer.",
                            "tags_add": ["node::concept-a"],
                            "tags_remove": ["legacy"],
                        }
                    ],
                }
            ]
        )

        with self.assertRaisesRegex(ReviewError, "new cards cannot remove tags"):
            self.compile()

    def test_emits_exact_edited_primer_as_a_copyable_file(self) -> None:
        primer_path = "/source/curriculum/primers/concept-a.html"
        original = "Original primer body."
        replacement = "Reviewed primer body."
        bundle = json.loads(
            (self.concepts / "concept-a.json").read_text(encoding="utf-8")
        )
        bundle["primer_path"] = primer_path
        bundle["primer_html"] = original
        (self.concepts / "concept-a.json").write_text(
            json.dumps(bundle), encoding="utf-8"
        )
        self.write_review(
            primer={
                "action": "edit",
                "path": primer_path,
                "rationale": "The replacement is more precise.",
                "html": replacement,
            }
        )

        summary = self.compile()

        self.assertEqual(summary["primer_edits"], 1)
        self.assertEqual(
            (self.compiled / "primer_files" / "concept-a.html").read_text(
                encoding="utf-8"
            ),
            replacement,
        )

    def test_emits_proposed_node_primer_as_a_copyable_file(self) -> None:
        self.write_review(
            proposed_nodes=[
                {
                    "node_id": "concept-adjacent",
                    "title": "Adjacent concept",
                    "module": "ML-extra",
                    "difficulty": 2,
                    "primer_html": "Reviewed adjacent primer.",
                    "rationale": "The adjacent concept deserves a distinct cluster.",
                }
            ]
        )

        summary = self.compile()

        self.assertEqual(summary["proposed_nodes"], 1)
        self.assertEqual(
            (self.compiled / "primer_files" / "concept-adjacent.html").read_text(
                encoding="utf-8"
            ),
            "Reviewed adjacent primer.",
        )

    def test_complete_compile_requires_and_emits_reviewed_figure_edit(self) -> None:
        figure_path = self.root / "concept-a.svg"
        figure_path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg"><text>Old</text></svg>',
            encoding="utf-8",
        )
        bundle = json.loads(
            (self.concepts / "concept-a.json").read_text(encoding="utf-8")
        )
        bundle["figure_path"] = str(figure_path)
        (self.concepts / "concept-a.json").write_text(
            json.dumps(bundle), encoding="utf-8"
        )
        self.write_review()
        with self.assertRaisesRegex(ReviewError, "figure was not independently reviewed"):
            self.compile()

        replacement = '<svg xmlns="http://www.w3.org/2000/svg"><text>Precise</text></svg>'
        self.write_review(
            figure={
                "action": "edit",
                "path": str(figure_path),
                "rationale": "The original label was misleading.",
                "svg": replacement,
            }
        )

        summary = self.compile()

        self.assertEqual(summary["figure_edits"], 1)
        self.assertEqual(
            (self.compiled / "figure_files" / "concept-a.svg").read_text(
                encoding="utf-8"
            ),
            replacement,
        )

    def test_placeholder_cluster_requires_a_move_for_every_card(self) -> None:
        bundle_path = self.concepts / "none.json"
        placeholder = {**self.bundle, "node_id": "none"}
        placeholder["cards"] = [
            {
                **self.bundle["cards"][0],
                "nid": 202,
                "tags": ["ml", "node::none"],
            }
        ]
        bundle_path.write_text(json.dumps(placeholder), encoding="utf-8")
        manifest = json.loads(self.concept_manifest.read_text(encoding="utf-8"))
        manifest.append(
            {
                "node_id": "none",
                "path": str(bundle_path),
                "card_count": 1,
                "has_primer": False,
                "decks": ["ML"],
            }
        )
        self.concept_manifest.write_text(json.dumps(manifest), encoding="utf-8")
        prep_manifest = json.loads((self.job / "manifest.json").read_text(encoding="utf-8"))
        prep_manifest["batches"].append("batch_002")
        prep_manifest["nids"].append(202)
        (self.job / "manifest.json").write_text(json.dumps(prep_manifest), encoding="utf-8")
        (self.job / "in" / "batch_002.json").write_text(
            json.dumps({"batch_id": "batch_002", "deck": "ML", "cards": placeholder["cards"]}),
            encoding="utf-8",
        )
        self.write_review()
        none_review = {
            "node_id": "none",
            "summary": "Placeholder reviewed.",
            "sources": [
                {
                    "title": "Authoritative placeholder reference",
                    "url": "https://example.invalid/placeholder",
                    "published_or_updated": "2026-01-01",
                    "accessed": "2026-08-11",
                    "supports": ["The reviewed placeholder content"],
                }
            ],
            "card_changes": [
                {
                    "nid": 202,
                    "action": "keep",
                    "rationale": "Content is valid but needs a real node.",
                    "score_before": 3,
                    "score_after": 4,
                    "cards": [
                        {
                            "front": "Original front?",
                            "back": "Original back.",
                            "tags_add": [],
                            "tags_remove": [],
                        }
                    ],
                }
            ],
            "new_cards": [],
            "node_moves": [],
            "primer": {"action": "missing", "path": None, "rationale": "No primer.", "html": None},
            "proposed_nodes": [],
            "unresolved": [],
        }
        (self.reviews / "none.json").write_text(json.dumps(none_review), encoding="utf-8")

        with self.assertRaisesRegex(ReviewError, "every placeholder card"):
            self.compile()

    def test_prep_manifest_nids_may_be_sorted_differently_from_batch_order(self) -> None:
        first = {**self.bundle["cards"][0], "nid": 202, "front": "Second-created front?"}
        second = self.bundle["cards"][0]
        bundle_path = self.concepts / "concept-a.json"
        bundle = {**self.bundle, "card_count": 2, "cards": [first, second]}
        bundle_path.write_text(json.dumps(bundle), encoding="utf-8")
        manifest = json.loads(self.concept_manifest.read_text(encoding="utf-8"))
        manifest[0]["card_count"] = 2
        self.concept_manifest.write_text(json.dumps(manifest), encoding="utf-8")
        (self.job / "manifest.json").write_text(
            json.dumps({"mode": "revise", "batches": ["batch_001"], "nids": [101, 202]}),
            encoding="utf-8",
        )
        (self.job / "in" / "batch_001.json").write_text(
            json.dumps({"batch_id": "batch_001", "deck": "ML", "cards": [first, second]}),
            encoding="utf-8",
        )
        self.write_review(
            card_changes=[
                {
                    "nid": 202,
                    "action": "keep",
                    "rationale": "Atomic and accurate.",
                    "score_before": 5,
                    "score_after": 5,
                    "cards": [
                        {
                            "front": "Second-created front?",
                            "back": "Original back.",
                            "tags_add": [],
                            "tags_remove": [],
                        }
                    ],
                },
                {
                    "nid": 101,
                    "action": "keep",
                    "rationale": "Atomic and accurate.",
                    "score_before": 5,
                    "score_after": 5,
                    "cards": [
                        {
                            "front": "Original front?",
                            "back": "Original back.",
                            "tags_add": [],
                            "tags_remove": [],
                        }
                    ],
                },
            ]
        )

        summary = self.compile()

        self.assertEqual(summary["existing_cards"], 2)


if __name__ == "__main__":
    unittest.main()

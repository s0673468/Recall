from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path


TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from apply_tag_mutations import (  # noqa: E402
    MutationError,
    apply_mutations,
    desired_tags,
    load_mutations,
)


class TagMutationTest(unittest.TestCase):
    def test_desired_tags_removes_old_node_and_preserves_unrelated_order(self) -> None:
        result = desired_tags(
            " deck::ml node::old marker::keep node::new ",
            {
                "nid": 7,
                "add": ["node::new"],
                "remove": ["node::old"],
                "expected_original_tags": ["deck::ml", "node::old", "marker::keep"],
            },
        )

        self.assertEqual(result, " deck::ml marker::keep node::new ")

    def test_desired_tags_accepts_exact_already_applied_state(self) -> None:
        mutation = {
            "nid": 7,
            "add": ["node::new"],
            "remove": ["node::old"],
            "expected_original_tags": ["deck::ml", "node::old"],
        }

        self.assertEqual(
            desired_tags(" deck::ml node::new pass::reviewed ", mutation),
            " deck::ml node::new pass::reviewed ",
        )

    def test_desired_tags_rejects_partial_or_concurrent_node_state(self) -> None:
        mutation = {
            "nid": 7,
            "add": ["node::new"],
            "remove": ["node::old", "legacy"],
            "expected_original_tags": ["node::old", "legacy"],
        }

        with self.assertRaisesRegex(MutationError, "partially applied"):
            desired_tags(" node::old node::new ", mutation)

        with self.assertRaisesRegex(MutationError, "unexpected node tag"):
            desired_tags(
                " node::old node::new node::concurrent legacy ", mutation
            )

    def test_load_mutations_rejects_duplicate_nids_and_add_remove_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "mutations.json"
            row = {
                "nid": 7,
                "add": ["node::new"],
                "remove": ["node::old"],
                "expected_original_tags": ["node::old"],
            }
            path.write_text(json.dumps([row, row]), encoding="utf-8")
            with self.assertRaisesRegex(MutationError, "duplicate nid"):
                load_mutations(path)

            row["remove"] = ["node::new"]
            path.write_text(json.dumps([row]), encoding="utf-8")
            with self.assertRaisesRegex(MutationError, "both add and remove"):
                load_mutations(path)

    def test_dry_run_does_not_write_and_apply_uses_exact_readback(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            db = root / "collection.anki2"
            backup = root / "before.anki2"
            backup.write_bytes(b"backup")
            connection = sqlite3.connect(db)
            connection.create_collation(
                "unicase", lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower())
            )
            connection.executescript(
                """
                CREATE TABLE notes (id INTEGER PRIMARY KEY, tags TEXT, mod INTEGER, usn INTEGER);
                CREATE TABLE tags (tag TEXT PRIMARY KEY COLLATE unicase, usn INTEGER, collapsed INTEGER, config TEXT);
                CREATE TABLE col (mod INTEGER);
                INSERT INTO notes VALUES (7, ' deck::ml node::old node::new ', 1, 0);
                INSERT INTO col VALUES (1);
                """
            )
            connection.commit()
            connection.close()
            mutations = [
                {
                    "nid": 7,
                    "add": ["node::new"],
                    "remove": ["node::old"],
                    "expected_original_tags": ["deck::ml", "node::old"],
                }
            ]

            dry_summary = apply_mutations(
                db_path=db,
                mutations=mutations,
                backup_path=backup,
                commit=False,
            )
            with closing(sqlite3.connect(db)) as check:
                self.assertEqual(
                    check.execute("SELECT tags FROM notes WHERE id=7").fetchone()[0],
                    " deck::ml node::old node::new ",
                )
            self.assertEqual(dry_summary["changed"], 1)

            summary = apply_mutations(
                db_path=db,
                mutations=mutations,
                backup_path=backup,
                commit=True,
            )
            with closing(sqlite3.connect(db)) as check:
                check.create_collation(
                    "unicase",
                    lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower()),
                )
                self.assertEqual(
                    check.execute("SELECT tags FROM notes WHERE id=7").fetchone()[0],
                    " deck::ml node::new ",
                )
                self.assertEqual(
                    check.execute(
                        "SELECT COUNT(*) FROM tags WHERE tag='node::new'"
                    ).fetchone()[0],
                    1,
                )
            self.assertEqual(summary["integrity"], "ok")
            self.assertEqual(summary["verified"], 1)


if __name__ == "__main__":
    unittest.main()

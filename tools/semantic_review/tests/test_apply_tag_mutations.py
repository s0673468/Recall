from __future__ import annotations

import json
import os
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
    def create_collection(
        self,
        path: Path,
        tags: str,
        *,
        collection_created: int = 1_700_000_000,
        deck_name: str = "ML",
    ) -> None:
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE notes (id INTEGER PRIMARY KEY, tags TEXT, mod INTEGER, usn INTEGER);
            CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER);
            CREATE TABLE tags (tag TEXT PRIMARY KEY, usn INTEGER, collapsed INTEGER, config TEXT);
            CREATE TABLE col (crt INTEGER, scm INTEGER, mod INTEGER);
            CREATE TABLE decks (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE notetypes (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE graves (oid INTEGER, type INTEGER, usn INTEGER);
            """
        )
        connection.execute("INSERT INTO notes VALUES (7, ?, 1, 0)", (tags,))
        connection.execute("INSERT INTO cards VALUES (70, 7)")
        connection.execute(
            "INSERT INTO col VALUES (?, 1700000100, 1)",
            (collection_created,),
        )
        connection.execute("INSERT INTO decks VALUES (1, ?)", (deck_name,))
        connection.execute("INSERT INTO notetypes VALUES (1, 'Basic')")
        connection.commit()
        connection.close()

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
            desired_tags(" node::old node::new node::concurrent legacy ", mutation)

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
            self.create_collection(db, " deck::ml node::old ")
            connection = sqlite3.connect(db)
            backup_connection = sqlite3.connect(backup)
            connection.backup(backup_connection)
            backup_connection.close()
            connection.execute(
                "UPDATE notes SET tags=' deck::ml node::old node::new ' WHERE id=7"
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

    def test_apply_rejects_backup_that_does_not_match_reviewed_original(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            db = root / "collection.anki2"
            backup = root / "wrong-backup.anki2"
            for path, tags in (
                (db, " node::old node::new "),
                (backup, " node::different "),
            ):
                self.create_collection(path, tags)
            mutation = {
                "nid": 7,
                "add": ["node::new"],
                "remove": ["node::old"],
                "expected_original_tags": ["node::old"],
            }

            with self.assertRaisesRegex(MutationError, "backup tags do not match"):
                apply_mutations(
                    db_path=db,
                    mutations=[mutation],
                    backup_path=backup,
                    commit=True,
                )

    def test_apply_rejects_live_database_or_hard_link_as_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            db = root / "collection.anki2"
            hard_link = root / "not-independent.anki2"
            self.create_collection(db, " node::old node::new ")
            os.link(db, hard_link)
            mutation = {
                "nid": 7,
                "add": ["node::new"],
                "remove": ["node::old"],
                "expected_original_tags": ["node::old"],
            }

            for path in (db, hard_link):
                with self.subTest(path=path.name):
                    with self.assertRaisesRegex(MutationError, "independent"):
                        apply_mutations(
                            db_path=db,
                            mutations=[mutation],
                            backup_path=path,
                            commit=True,
                        )

    def test_apply_rejects_minimal_or_different_collection_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            db = root / "collection.anki2"
            minimal = root / "minimal.anki2"
            different = root / "different.anki2"
            self.create_collection(db, " node::old node::new ")
            self.create_collection(
                different,
                " node::old ",
                collection_created=1_600_000_000,
            )
            connection = sqlite3.connect(minimal)
            connection.executescript(
                """
                CREATE TABLE notes (id INTEGER PRIMARY KEY, tags TEXT);
                INSERT INTO notes VALUES (7, ' node::old ');
                """
            )
            connection.commit()
            connection.close()
            mutation = {
                "nid": 7,
                "add": ["node::new"],
                "remove": ["node::old"],
                "expected_original_tags": ["node::old"],
            }

            with self.assertRaisesRegex(MutationError, "complete Anki collection"):
                apply_mutations(
                    db_path=db,
                    mutations=[mutation],
                    backup_path=minimal,
                    commit=True,
                )
            with self.assertRaisesRegex(MutationError, "different Anki collection"):
                apply_mutations(
                    db_path=db,
                    mutations=[mutation],
                    backup_path=different,
                    commit=True,
                )


if __name__ == "__main__":
    unittest.main()

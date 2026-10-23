"""Tag retries must preserve the collection's sync metadata."""

import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock

import test_apply_tag_mutations as fixtures
import apply_tag_mutations as tags


class TagRetryTests(unittest.TestCase):
    def test_retry_is_a_noop_for_database_bytes_and_sync_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db, backup = root / "synthetic.anki2", root / "before.anki2"
            fixtures.TagMutationTest().create_collection(db, " node::old ")
            with closing(sqlite3.connect(db)) as source, closing(sqlite3.connect(backup)) as target:
                source.backup(target)
                source.execute("UPDATE notes SET tags=' node::old node::new '")
                source.commit()
            mutations = [{
                "nid": 7,
                "add": ["node::new"],
                "remove": ["node::old"],
                "expected_original_tags": ["node::old"],
            }]
            with mock.patch.object(tags.time, "time", return_value=100):
                first = tags.apply_mutations(
                    db_path=db, mutations=mutations, backup_path=backup, commit=True,
                )
            self.assertEqual(first["changed"], 1)
            after_first = db.read_bytes()
            with mock.patch.object(tags.time, "time", return_value=200):
                for commit in (False, True):
                    with self.subTest(commit=commit):
                        summary = tags.apply_mutations(
                            db_path=db, mutations=mutations, backup_path=backup, commit=commit,
                        )
                        self.assertEqual(summary["changed"], 0)
                        self.assertEqual(summary["already_applied"], 1)
                        self.assertEqual(db.read_bytes(), after_first)
            self.assertEqual(summary["verified"], 1)
            self.assertEqual(summary["integrity"], "ok")


if __name__ == "__main__":
    unittest.main()

"""Overlapping imports of empty synthetic decks, with no network or content."""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_import_to_supabase import Collection, FakeSupabase, importer


class TimestampedSupabase(FakeSupabase):
    """Model the decks table's default and touch_updated_at trigger."""

    def __init__(self):
        super().__init__(max_rows=2)
        self.version = 0

    def timestamp(self):
        self.version += 1
        return f"2026-10-22T00:00:00.{self.version:06d}+00:00"

    def add(self, table, row):
        if table == "decks":
            row = {**row, "updated_at": self.timestamp()}
        return super().add(table, row)

    def rewrite(self, table, row, values):
        if table == "decks":
            values = {**values, "updated_at": self.timestamp()}
        super().rewrite(table, row, values)


class OverlappingDeckImportsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.collection = Collection(self.root / "synthetic.anki2")
        self.addCleanup(self.collection.con.close)
        self.collection.con.execute("DELETE FROM decks WHERE id != 1")
        self.cloud = TimestampedSupabase()
        self.owner = "synthetic-owner"

    def run_import(self):
        self.collection.con.commit()
        with (
            mock.patch.object(importer, "LIVE_DB", str(self.collection.path)),
            mock.patch.object(importer, "USER_ID", self.owner),
            mock.patch.object(tempfile, "tempdir", str(self.root)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            importer.run(self.cloud)

    def add_cloud_deck(self, did):
        return self.cloud.add("decks", {
            "user_id": self.owner,
            "deck_id": did,
            "name": f"Synthetic {did}",
            "deleted": False,
        })

    def publish_newer_snapshot(self):
        self.cloud.before_write = None
        self.collection.con.execute("INSERT INTO decks VALUES (2, 'New empty deck')")
        self.run_import()

    def assert_newer_deck_is_visible(self):
        self.assertEqual(
            {d["deck_id"] for d in self.cloud.tables["decks"] if not d["deleted"]},
            {1, 2},
        )
        self.assertEqual(self.cloud.tables["notes"], [])
        self.assertEqual(self.cloud.tables["cards"], [])

    def test_newer_imports_new_empty_deck_survives_older_cleanup(self):
        stale = self.add_cloud_deck(3)

        def overlap(query):
            if query.table_name == "notes" and query.action == "upsert":
                self.publish_newer_snapshot()

        self.cloud.before_write = overlap
        self.run_import()

        self.assert_newer_deck_is_visible()
        self.assertTrue(stale["deleted"])

    def test_newer_imports_existing_empty_deck_survives_older_cleanup(self):
        deck = self.add_cloud_deck(2)
        identity = deck["id"]

        def overlap(query):
            if query.table_name == "notes" and query.action == "upsert":
                self.publish_newer_snapshot()

        self.cloud.before_write = overlap
        self.run_import()

        self.assert_newer_deck_is_visible()
        self.assertEqual(deck["id"], identity)

    def test_newer_publish_between_cleanup_read_and_write_survives(self):
        self.add_cloud_deck(2)

        def overlap(query):
            if query.table_name == "decks" and query.action == "update":
                self.publish_newer_snapshot()

        self.cloud.before_write = overlap
        self.run_import()

        self.assert_newer_deck_is_visible()


if __name__ == "__main__":
    unittest.main()

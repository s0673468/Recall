"""Deck metadata regressions using an invented collection and in-memory cloud."""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_import_to_supabase import Collection, FakeSupabase, importer


class DeckManagementTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.collection = Collection(self.root / "synthetic.anki2")
        self.addCleanup(self.collection.con.close)
        self.cloud = FakeSupabase(max_rows=2)
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

    def test_removed_decks_are_tombstoned_without_deleting_rows(self):
        for did in range(100, 1103):
            self.cloud.add("decks", {
                "user_id": self.owner,
                "deck_id": did,
                "name": f"Removed {did}",
                "deleted": False,
            })
        other = self.cloud.add("decks", {
            "user_id": "other-synthetic-owner",
            "deck_id": 100,
            "name": "Other owner",
            "deleted": False,
        })
        self.run_import()

        own = [d for d in self.cloud.tables["decks"] if d["user_id"] == self.owner]
        self.assertEqual({d["deck_id"] for d in own if not d["deleted"]}, {1, 2, 99})
        self.assertEqual(len(own), 1006)
        self.assertFalse(other["deleted"])

    def test_rename_nesting_move_and_reappearance_preserve_deck_identity(self):
        self.run_import()
        original_ids = {d["deck_id"]: d["id"] for d in self.cloud.tables["decks"]}
        self.collection.con.execute(
            "UPDATE decks SET name='Opt-in::Nested::Home' WHERE id=1"
        )
        self.collection.con.execute("DELETE FROM decks WHERE id=2")
        self.run_import()
        removed = next(d for d in self.cloud.tables["decks"] if d["deck_id"] == 2)
        self.assertTrue(removed["deleted"])
        self.collection.con.execute("INSERT INTO decks VALUES (2, 'Restored::Home')")
        self.run_import()

        own = {d["deck_id"]: d for d in self.cloud.tables["decks"]}
        self.assertEqual(len(own), 3)
        self.assertEqual({did: d["id"] for did, d in own.items()}, original_ids)
        self.assertEqual(own[1]["name"], "Opt-in::Nested::Home")
        self.assertEqual(own[2]["name"], "Restored::Home")
        self.assertFalse(own[2]["deleted"])

    def test_filtered_deck_uses_renamed_home_deck_id(self):
        self.collection.con.execute("UPDATE decks SET name='Root::Moved' WHERE id=2")
        self.collection.card(1, ctype=2, queue=2, due=-100, did=99, odid=2, odue=700)
        with mock.patch.object(importer, "USER_ID", self.owner):
            decks, notes, _, _ = self.collection.payloads()
        self.assertEqual(notes[0]["deck_id"], 2)
        self.assertEqual(
            next(d["name"] for d in decks if d["deck_id"] == 2), "Root::Moved"
        )


if __name__ == "__main__":
    unittest.main()

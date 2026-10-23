"""Synthetic WAL collections exercise the real importer without a network."""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_import_to_supabase import Collection, FakeSupabase, importer


class CloudWithDefaults(FakeSupabase):
    def add(self, table, row):
        if table == "cards":
            row = {"cloud_seen": False, **row}
        return super().add(table, row)


class ImportSnapshotTests(unittest.TestCase):
    def test_source_change_during_parsing_does_not_mix_decks_and_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            collection = Collection(Path(directory) / "synthetic.anki2")
            self.addCleanup(collection.con.close)
            collection.card(1, ctype=0, queue=0, due=1)
            collection.con.commit()
            cloud = CloudWithDefaults()
            read_decks = importer.deck_name_to_id

            def add_deck_after_read(connection):
                decks = read_decks(connection)
                collection.con.execute("INSERT INTO decks VALUES (3, 'Synthetic new deck')")
                collection.card(2, ctype=0, queue=0, due=2, did=3)
                collection.con.commit()
                return decks

            with (
                mock.patch.object(importer, "LIVE_DB", str(collection.path)),
                mock.patch.object(importer, "deck_name_to_id", side_effect=add_deck_after_read),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                importer.run(cloud)

            self.assertEqual([n["guid"] for n in cloud.tables["notes"]], ["guid-1"])
            self.assertNotIn(3, {d["deck_id"] for d in cloud.tables["decks"]})

    def test_import_reads_committed_wal_and_preserves_identity_on_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collection = Collection(root / "synthetic.anki2")
            self.addCleanup(collection.con.close)
            collection.con.commit()
            collection.con.execute("PRAGMA journal_mode=WAL")
            collection.con.execute("PRAGMA wal_autocheckpoint=0")
            guid = collection.card(1, ctype=2, queue=2, due=700)
            collection.con.commit()
            self.assertGreater(Path(f"{collection.path}-wal").stat().st_size, 0)
            cloud = CloudWithDefaults()

            with (
                mock.patch.object(importer, "LIVE_DB", str(collection.path)),
                mock.patch.object(tempfile, "tempdir", str(root)),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                importer.run(cloud)
                self.assertEqual([n["guid"] for n in cloud.tables["notes"]], [guid])
                note_id = cloud.tables["notes"][0]["id"]
                card_id = cloud.tables["cards"][0]["id"]
                # A move committed only to WAL must update the same cloud note.
                collection.con.execute("UPDATE cards SET did=2, lapses=4 WHERE id=1")
                collection.con.commit()
                importer.run(cloud)

            self.assertEqual(len(cloud.tables["notes"]), 1)
            self.assertEqual(cloud.tables["notes"][0]["id"], note_id)
            self.assertEqual(cloud.tables["notes"][0]["deck_id"], 2)
            self.assertEqual(cloud.tables["cards"][0]["id"], card_id)
            self.assertEqual(cloud.tables["cards"][0]["note_id"], note_id)
            self.assertEqual(cloud.tables["cards"][0]["lapses"], 4)
            self.assertFalse(cloud.tables["cards"][0]["deleted"])
            self.assertFalse((root / "anki_import_copy.anki2").exists())

    def test_dry_run_and_apply_parse_the_same_isolated_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            collection = Collection(Path(directory) / "synthetic.anki2")
            self.addCleanup(collection.con.close)
            collection.card(1, ctype=0, queue=0, due=1)
            collection.con.commit()
            original = collection.path.read_bytes()
            payloads = []
            build_payloads = importer.build_payloads

            def capture(connection):
                payload = build_payloads(connection)
                payloads.append(payload)
                return payload

            with (
                mock.patch.object(importer, "LIVE_DB", str(collection.path)),
                mock.patch.object(importer, "build_payloads", side_effect=capture),
                mock.patch.object(tempfile, "tempdir", directory),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                importer.dry_run()
                self.assertEqual(collection.path.read_bytes(), original)
                importer.run(FakeSupabase())

            self.assertEqual(payloads[0], payloads[1])
            self.assertEqual(collection.path.read_bytes(), original)
            self.assertEqual({p.name for p in Path(directory).iterdir()}, {"synthetic.anki2"})


if __name__ == "__main__":
    unittest.main()

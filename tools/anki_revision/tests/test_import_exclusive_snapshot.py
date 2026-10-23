"""Only invented collections; no Anki desktop, credentials, or network."""

import contextlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_import_to_supabase import Collection, FakeSupabase, importer


class ExclusiveSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.collection = Collection(self.root / "synthetic.anki2")
        self.addCleanup(self.collection.con.close)
        self.collection.con.commit()

    def read_payloads(self):
        with (
            mock.patch.object(importer, "LIVE_DB", str(self.collection.path)),
            mock.patch.object(tempfile, "tempdir", str(self.root)),
        ):
            return importer._read_payloads()

    def assert_only_collection_files_remain(self):
        self.assertTrue(all(p.name.startswith("synthetic.anki2") for p in self.root.iterdir()))

    def test_import_and_dry_run_read_wal_under_anki_exclusive_lock(self):
        writer = self.collection.con
        self.assertEqual(writer.execute("PRAGMA locking_mode=EXCLUSIVE").fetchone(),
                         ("exclusive",))
        self.assertEqual(writer.execute("PRAGMA journal_mode=WAL").fetchone(), ("wal",))
        writer.execute("PRAGMA wal_autocheckpoint=0")
        self.collection.card(1, ctype=2, queue=2, due=700)
        writer.commit()
        wal = Path(f"{self.collection.path}-wal")
        self.assertGreater(wal.stat().st_size, 0)
        self.assertFalse(Path(f"{self.collection.path}-shm").exists())
        # A separate process gives this regression a hard deadline even if
        # SQLite's backup API keeps retrying SQLITE_BUSY indefinitely.
        program = """
import contextlib
import io
import sqlite3
import sys
from pathlib import Path
from unittest import mock
from test_import_to_supabase import FakeSupabase, importer

importer.LIVE_DB = sys.argv[1]
source = Path(importer.LIVE_DB)
wal = Path(str(source) + '-wal')
original = (source.read_bytes(), wal.read_bytes())
with contextlib.closing(sqlite3.connect(importer.LIVE_DB, timeout=0.01)) as reader:
    try:
        reader.execute('SELECT COUNT(*) FROM cards')
    except sqlite3.OperationalError as error:
        assert 'locked' in str(error)
    else:
        raise AssertionError('fixture must hold the exclusive file lock')
parse = importer.build_payloads
payloads = []

def capture(connection):
    payload = parse(connection)
    assert [n['guid'] for n in payload[1]] == ['guid-1']
    assert connection.execute('PRAGMA journal_mode').fetchone() == ('delete',)
    snapshot = Path(connection.execute('PRAGMA database_list').fetchone()[2])
    assert snapshot.parent.stat().st_mode & 0o777 == 0o700
    assert not Path(str(snapshot) + '-wal').exists()
    payloads.append(payload)
    return payload

cloud = FakeSupabase()
with mock.patch.object(importer, 'build_payloads', side_effect=capture):
    with contextlib.redirect_stdout(io.StringIO()):
        importer.run(cloud)
        importer.dry_run()
assert [n['guid'] for n in cloud.tables['notes']] == ['guid-1']
assert payloads[0] == payloads[1]
assert (source.read_bytes(), wal.read_bytes()) == original
print('snapshot-ok')
"""
        result = subprocess.run(
            [sys.executable, "-c", program, str(self.collection.path)],
            env={"PYTHONPATH": str(Path(__file__).parent), "TMPDIR": str(self.root)},
            capture_output=True, text=True, timeout=3,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "snapshot-ok")
        self.assertEqual({p.name for p in self.root.iterdir()},
                         {"synthetic.anki2", "synthetic.anki2-wal"})

    def test_plain_database_copy_never_opens_live_source_with_sqlite(self):
        self.collection.card(1, ctype=0, queue=0, due=1)
        self.collection.con.commit()
        original = self.collection.path.read_bytes()
        connect = importer.connect
        opened = []

        def private_only(path, **kwargs):
            self.assertNotEqual(Path(path).resolve(), self.collection.path.resolve())
            opened.append(path)
            return connect(path, **kwargs)

        with mock.patch.object(importer, "connect", side_effect=private_only):
            payload = self.read_payloads()

        self.assertTrue(opened)
        self.assertEqual([n["guid"] for n in payload[1]], ["guid-1"])
        self.assertEqual(self.collection.path.read_bytes(), original)
        self.assert_only_collection_files_remain()

    def test_retries_when_database_changes_during_copy(self):
        self.collection.card(1, ctype=0, queue=0, due=1)
        self.collection.con.commit()
        copyfile = shutil.copyfile
        attempts = []

        def mutate_after_copy(source, destination):
            copyfile(source, destination)
            attempts.append(destination)
            if len(attempts) == 1:
                self.collection.card(2, ctype=0, queue=0, due=2)
                self.collection.con.commit()

        with mock.patch.object(importer.shutil, "copyfile", side_effect=mutate_after_copy):
            payload = self.read_payloads()

        self.assertEqual(len(attempts), 2)
        self.assertNotEqual(attempts[0].parent, attempts[1].parent)
        self.assertEqual({n["guid"] for n in payload[1]}, {"guid-1", "guid-2"})
        self.assert_only_collection_files_remain()

    def test_retries_when_only_wal_changes_during_copy(self):
        writer = self.collection.con
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        self.collection.card(1, ctype=0, queue=0, due=1)
        writer.commit()
        copyfile = shutil.copyfile
        wal_copies = []

        def mutate_after_wal_copy(source, destination):
            copyfile(source, destination)
            if str(source).endswith("-wal"):
                wal_copies.append(destination)
                if len(wal_copies) == 1:
                    self.collection.card(2, ctype=0, queue=0, due=2)
                    writer.commit()

        with mock.patch.object(importer.shutil, "copyfile", side_effect=mutate_after_wal_copy):
            payload = self.read_payloads()

        self.assertEqual(len(wal_copies), 2)
        self.assertEqual({n["guid"] for n in payload[1]}, {"guid-1", "guid-2"})
        self.assert_only_collection_files_remain()

    def test_retries_when_wal_appears_during_copy(self):
        self.collection.card(1, ctype=0, queue=0, due=1)
        self.collection.con.commit()
        copyfile = shutil.copyfile
        copies = []

        def create_wal_after_copy(source, destination):
            copyfile(source, destination)
            copies.append(destination)
            if len(copies) == 1:
                self.collection.con.execute("PRAGMA journal_mode=WAL")
                self.collection.card(2, ctype=0, queue=0, due=2)
                self.collection.con.commit()

        with mock.patch.object(importer.shutil, "copyfile", side_effect=create_wal_after_copy):
            payload = self.read_payloads()

        self.assertEqual(len(copies), 3)  # first DB, then a fresh DB + WAL
        self.assertEqual({n["guid"] for n in payload[1]}, {"guid-1", "guid-2"})
        self.assert_only_collection_files_remain()

    def test_retries_when_wal_disappears_during_copy(self):
        writer = self.collection.con
        writer.execute("PRAGMA journal_mode=WAL")
        self.collection.card(1, ctype=0, queue=0, due=1)
        writer.commit()
        copyfile = shutil.copyfile
        copies = []

        def close_writer_after_copy(source, destination):
            copies.append(destination)
            copyfile(source, destination)
            if len(copies) == 1:
                writer.close()  # checkpoints and removes the source WAL

        with mock.patch.object(importer.shutil, "copyfile", side_effect=close_writer_after_copy):
            payload = self.read_payloads()

        self.assertEqual(len(copies), 3)  # first DB, missing WAL, fresh DB
        self.assertEqual([n["guid"] for n in payload[1]], ["guid-1"])
        self.assert_only_collection_files_remain()

    def test_retries_invalid_private_database_before_parsing(self):
        self.collection.card(1, ctype=0, queue=0, due=1)
        self.collection.con.commit()
        copyfile = shutil.copyfile
        copies = []

        def damage_first_copy(source, destination):
            copyfile(source, destination)
            copies.append(destination)
            if len(copies) == 1:
                Path(destination).write_bytes(b"synthetic invalid SQLite file")

        with (
            mock.patch.object(importer.shutil, "copyfile", side_effect=damage_first_copy),
            mock.patch.object(importer, "build_payloads", wraps=importer.build_payloads) as parse,
        ):
            payload = self.read_payloads()

        self.assertEqual(len(copies), 2)
        self.assertEqual(parse.call_count, 1)
        self.assertEqual([n["guid"] for n in payload[1]], ["guid-1"])
        self.assert_only_collection_files_remain()

    def test_continuously_changing_source_fails_both_entrypoints_without_writes(self):
        self.collection.card(1, ctype=0, queue=0, due=1)
        self.collection.con.commit()
        copyfile = shutil.copyfile

        def change_after_every_copy(source, destination):
            copyfile(source, destination)
            self.collection.con.execute("UPDATE col SET crt=crt+1")
            self.collection.con.commit()

        cloud = FakeSupabase()
        for entrypoint in (lambda: importer.run(cloud), importer.dry_run):
            with (
                self.subTest(entrypoint=entrypoint),
                mock.patch.object(importer, "LIVE_DB", str(self.collection.path)),
                mock.patch.object(tempfile, "tempdir", str(self.root)),
                mock.patch.object(importer.shutil, "copyfile", side_effect=change_after_every_copy) as copy,
                mock.patch.object(importer, "build_payloads") as parse,
                contextlib.redirect_stdout(io.StringIO()),
                self.assertRaisesRegex(RuntimeError, "consistent Anki snapshot after 3 attempts"),
            ):
                entrypoint()
            self.assertEqual(copy.call_count, 3)
            parse.assert_not_called()
            self.assertTrue(all(not rows for rows in cloud.tables.values()))
            self.assert_only_collection_files_remain()

    def test_missing_source_fails_clearly_without_leaving_a_snapshot(self):
        with (
            mock.patch.object(importer, "LIVE_DB", str(self.root / "missing.anki2")),
            mock.patch.object(tempfile, "tempdir", str(self.root)),
            self.assertRaisesRegex(RuntimeError, "consistent Anki snapshot after 3 attempts") as error,
        ):
            importer._read_payloads()
        self.assertIn("collection is missing", str(error.exception.__cause__))
        self.assert_only_collection_files_remain()

    def test_parse_error_is_not_retried_and_private_copy_is_removed(self):
        with (
            mock.patch.object(importer, "build_payloads", side_effect=ValueError("synthetic parse failure")) as parse,
            self.assertRaisesRegex(ValueError, "synthetic parse failure"),
        ):
            self.read_payloads()
        self.assertEqual(parse.call_count, 1)
        self.assert_only_collection_files_remain()


if __name__ == "__main__":
    unittest.main()

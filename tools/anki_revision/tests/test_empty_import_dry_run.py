"""Exercise the dry-run CLI against empty, synthetic SQLite collections."""

import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_import_to_supabase import SCHEMA, TOOL_ROOT


class EmptyImportDryRunTests(unittest.TestCase):
    def test_empty_collection_exits_zero_without_writes_or_network(self):
        for has_deck in (False, True):
            with self.subTest(has_deck=has_deck), tempfile.TemporaryDirectory() as directory:
                db = Path(directory) / "collection.anki2"
                with sqlite3.connect(db) as connection:
                    connection.executescript(SCHEMA)
                    connection.execute("INSERT INTO col VALUES (1700000000)")
                    if has_deck:
                        connection.execute("INSERT INTO decks VALUES (1, 'Synthetic')")
                connection.close()
                before = db.read_bytes()
                before_stat = db.stat()
                # Run the real __main__ path in a fresh process with networking
                # disabled and no inherited runtime credentials or personal paths.
                result = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        "import runpy, sys; from unittest import mock; "
                        "sys.path.insert(0, sys.argv[1]); "
                        "sys.argv = [sys.argv[1] + '/import_to_supabase.py', '--dry-run']; "
                        "guard = mock.patch('socket.socket', side_effect=AssertionError('network forbidden')); "
                        "guard.start(); runpy.run_path(sys.argv[0], run_name='__main__')",
                        str(TOOL_ROOT),
                    ],
                    env={"ANKI_COLLECTION": str(db), "PYTHONDONTWRITEBYTECODE": "1"},
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertIn(
                    f"decks={int(has_deck)} notes=0 cards=0 "
                    "has_latex=0 review_state=0 new_state=0",
                    result.stdout,
                )
                self.assertNotIn("sample note:", result.stdout)
                self.assertNotIn("sample card:", result.stdout)
                self.assertEqual(db.read_bytes(), before)
                self.assertEqual(db.stat().st_mtime_ns, before_stat.st_mtime_ns)
                self.assertEqual(list(Path(directory).iterdir()), [db])


if __name__ == "__main__":
    unittest.main()

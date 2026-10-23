"""Source selection and resumability, using only synthetic local files."""

import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import test_run_autosync as fixtures

run_autosync = fixtures.run_autosync


class CollectionSourceTests(unittest.TestCase):
    def run_sync(self, paths, runner):
        repo, runtime, collection, concepts, log = paths
        return run_autosync.run_once(
            repo_root=repo,
            runtime_dir=runtime,
            collection=collection,
            concepts=concepts,
            log_path=log,
            settle_seconds=0,
            command_runner=runner,
            # Only source values are synthetic; configuration completeness is mocked.
            env_loader=lambda _: {},
        )

    def test_importer_receives_the_selected_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = fixtures.AutosyncTests().fixture(Path(directory))
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
            with (
                mock.patch.object(run_autosync, "REQUIRED_ENV", ()),
                mock.patch.dict(os.environ, {"ANKI_COLLECTION": "unselected.anki2"}),
            ):
                self.assertEqual(self.run_sync(paths, runner), 0)
            self.assertEqual(
                runner.call_args_list[0].kwargs["env"]["ANKI_COLLECTION"],
                str(paths[2].resolve()),
            )

    def test_wal_only_commit_is_retried_after_partial_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = fixtures.AutosyncTests().fixture(Path(directory))
            collection = paths[2]
            collection.unlink()  # Replace the invented byte fixture with synthetic SQLite.
            with sqlite3.connect(collection) as writer:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.execute("PRAGMA wal_autocheckpoint=0")
                writer.execute("CREATE TABLE source_revision (id INTEGER)")
                writer.commit()
                runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
                with mock.patch.object(run_autosync, "REQUIRED_ENV", ()):
                    self.assertEqual(self.run_sync(paths, runner), 0)
                    first_stamp = (paths[1] / ".last_sync_mtime").read_bytes()
                    main_mtime = collection.stat().st_mtime_ns
                    wal = Path(f"{collection}-wal")
                    previous_wal_mtime = wal.stat().st_mtime_ns
                    writer.execute("INSERT INTO source_revision VALUES (1)")
                    writer.commit()
                    # Make the regression independent of filesystem clock resolution.
                    os.utime(wal, ns=(previous_wal_mtime + 1, previous_wal_mtime + 1))
                    self.assertEqual(collection.stat().st_mtime_ns, main_mtime)

                    runner.reset_mock()
                    runner.side_effect = [
                        subprocess.CompletedProcess([], 1),
                        subprocess.CompletedProcess([], 0),
                    ]
                    self.assertEqual(self.run_sync(paths, runner), 1)
                    self.assertEqual(runner.call_count, 2)
                    self.assertEqual((paths[1] / ".last_sync_mtime").read_bytes(), first_stamp)

                    runner.reset_mock()
                    runner.side_effect = None
                    self.assertEqual(self.run_sync(paths, runner), 0)
                    self.assertEqual(runner.call_count, 2)
                    runner.reset_mock()
                    self.assertEqual(self.run_sync(paths, runner), 0)
                    runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()

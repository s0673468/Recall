from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import install_runtime
import run_autosync


class OperationalLogTests(unittest.TestCase):
    def test_log_is_private_canonical_and_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            for index in range(140):
                event = run_autosync._event(
                    operation="import_collection",
                    outcome="failed",
                    cause_code="import_collection_failed",
                    retryable=True,
                    run_id=f"run-{index}",
                )
                run_autosync.append_event(path, event)

            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertLessEqual(len(lines), run_autosync.MAX_EVENTS)
            self.assertLessEqual(path.stat().st_size, run_autosync.MAX_LOG_BYTES)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertTrue(all(json.loads(line)["schema"] == run_autosync.SCHEMA for line in lines))
            self.assertNotIn("run-0", path.read_text(encoding="utf-8"))

    def test_rejects_non_canonical_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "non-canonical"):
                run_autosync.append_event(
                    Path(directory) / "events.jsonl",
                    {"schema": run_autosync.SCHEMA, "detail": "private"},
                )


class AutosyncTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, Path, Path, Path, Path]:
        repo = root / "repo"
        runtime = root / "runtime"
        collection = root / "collection.anki2"
        concepts = root / "concepts.yaml"
        log = root / "events.jsonl"
        (repo / "tools/anki_revision").mkdir(parents=True)
        (repo / "tools/recall_sync").mkdir(parents=True)
        runtime.mkdir()
        collection.write_bytes(b"anki")
        concepts.write_text("nodes: []\n", encoding="utf-8")
        (repo / "tools/anki_revision/import_to_supabase.py").write_text("", encoding="utf-8")
        (repo / "tools/recall_sync/sync_concept_nodes.py").write_text("", encoding="utf-8")
        return repo, runtime, collection, concepts, log

    def test_unchanged_collection_runs_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            (runtime / ".last_sync_mtime").write_text(
                f"{collection.stat().st_mtime_ns}:{concepts.stat().st_mtime_ns}",
                encoding="utf-8",
            )
            runner = mock.Mock()
            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )
            self.assertEqual(result, 0)
            runner.assert_not_called()
            self.assertFalse(log.exists())

    def test_success_updates_private_stamp_and_records_closed_events(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            runner = mock.Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 0),
                    subprocess.CompletedProcess([], 0),
                ]
            )
            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )
            self.assertEqual(result, 0)
            self.assertEqual(runner.call_count, 2)
            stamp = runtime / ".last_sync_mtime"
            self.assertEqual(
                stamp.read_text().strip(),
                f"{collection.stat().st_mtime_ns}:{concepts.stat().st_mtime_ns}",
            )
            self.assertEqual(stat.S_IMODE(stamp.stat().st_mode), 0o600)
            events = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([event["outcome"] for event in events], ["succeeded", "succeeded"])
            self.assertTrue(all("detail" not in event for event in events))

    def test_import_failure_does_not_advance_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            runner = mock.Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 2),
                    subprocess.CompletedProcess([], 0),
                ]
            )
            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )
            self.assertEqual(result, 1)
            self.assertFalse((runtime / ".last_sync_mtime").exists())
            events = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(events[0]["cause_code"], "import_collection_failed")
            self.assertEqual(events[1]["outcome"], "succeeded")

    def test_subprocess_start_failure_becomes_value_free_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=mock.Mock(side_effect=OSError("private path")),
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )
            self.assertEqual(result, 1)
            contents = log.read_text(encoding="utf-8")
            self.assertNotIn("private path", contents)
            events = [json.loads(line) for line in contents.splitlines()]
            self.assertEqual(
                [event["cause_code"] for event in events],
                ["import_collection_failed", "sync_concepts_failed"],
            )

    def test_subsecond_collection_change_is_not_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            previous = 1_000_100_000_000
            current = 1_000_900_000_000
            os.utime(collection, ns=(previous, previous))
            (runtime / ".last_sync_mtime").write_text(
                f"{previous}:{concepts.stat().st_mtime_ns}", encoding="utf-8"
            )
            os.utime(collection, ns=(current, current))
            runner = mock.Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 0),
                    subprocess.CompletedProcess([], 0),
                ]
            )

            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )

            self.assertEqual(result, 0)
            self.assertEqual(runner.call_count, 2)

    def test_concept_change_is_part_of_the_source_revision(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            (runtime / ".last_sync_mtime").write_text(
                f"{collection.stat().st_mtime_ns}:{concepts.stat().st_mtime_ns}",
                encoding="utf-8",
            )
            concept_revision = concepts.stat().st_mtime_ns + 1_000_000_000
            os.utime(concepts, ns=(concept_revision, concept_revision))
            runner = mock.Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 0),
                    subprocess.CompletedProcess([], 0),
                ]
            )

            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )

            self.assertEqual(result, 0)
            self.assertEqual(runner.call_count, 2)
            self.assertEqual(
                runner.call_args_list[1].kwargs["env"]["METIS_CONCEPTS_YAML"],
                str(concepts.resolve()),
            )

    def test_private_env_concept_override_controls_revision_and_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            override = Path(directory) / "alternate-concepts.yaml"
            override.write_text("nodes: []\n", encoding="utf-8")
            (runtime / ".last_sync_mtime").write_text(
                f"{collection.stat().st_mtime_ns}:{concepts.stat().st_mtime_ns}",
                encoding="utf-8",
            )
            runner = mock.Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 0),
                    subprocess.CompletedProcess([], 0),
                ]
            )

            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                    "METIS_CONCEPTS_YAML": str(override),
                },
            )

            self.assertEqual(result, 0)
            self.assertEqual(runner.call_count, 2)
            self.assertEqual(
                runner.call_args_list[1].kwargs["env"]["METIS_CONCEPTS_YAML"],
                str(override.resolve()),
            )
            self.assertEqual(
                (runtime / ".last_sync_mtime").read_text().strip(),
                f"{collection.stat().st_mtime_ns}:{override.stat().st_mtime_ns}",
            )

    def test_timeout_is_bounded_logged_and_leaves_the_stamp_pending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            runner = mock.Mock(
                side_effect=[
                    subprocess.TimeoutExpired(["import"], 1),
                    subprocess.CompletedProcess([], 0),
                ]
            )

            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )

            self.assertEqual(result, 1)
            self.assertFalse((runtime / ".last_sync_mtime").exists())
            self.assertEqual(
                runner.call_args_list[0].kwargs["timeout"],
                run_autosync.COMMAND_TIMEOUT_SECONDS,
            )
            events = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(events[0]["cause_code"], "import_collection_failed")
            with (runtime / ".autosync.lock").open("a+") as lock:
                run_autosync.fcntl.flock(
                    lock.fileno(), run_autosync.fcntl.LOCK_EX | run_autosync.fcntl.LOCK_NB
                )

    def test_concept_failure_is_retryable_and_does_not_advance_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, runtime, collection, concepts, log = self.fixture(Path(directory))
            runner = mock.Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 0),
                    subprocess.CompletedProcess([], 2),
                ]
            )

            result = run_autosync.run_once(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                settle_seconds=0,
                command_runner=runner,
                env_loader=lambda _: {
                    "SUPABASE_URL": "https://example.invalid",
                    "SUPABASE_SERVICE_KEY": "secret",
                },
            )

            self.assertEqual(result, 1)
            self.assertFalse((runtime / ".last_sync_mtime").exists())
            events = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertTrue(events[1]["retryable"])


class InstallerTests(unittest.TestCase):
    def test_private_env_concept_override_controls_watch_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "runtime"
            runtime.mkdir()
            override = Path(directory) / "alternate-concepts.yaml"
            (runtime / ".env").write_text(
                f"METIS_CONCEPTS_YAML={override}\n", encoding="utf-8"
            )

            result = install_runtime.effective_concepts_path(
                runtime_dir=runtime,
                configured=Path(directory) / "default-concepts.yaml",
            )

            self.assertEqual(result, override.resolve())

    def test_plist_runs_reviewed_source_and_discards_raw_output(self) -> None:
        payload = install_runtime.build_plist(
            python=Path("/runtime/.venv/bin/python"),
            runner=Path("/repo/tools/recall_sync/run_autosync.py"),
            repo_root=Path("/repo"),
            runtime_dir=Path("/runtime"),
            collection=Path("/collection.anki2"),
            concepts=Path("/concepts.yaml"),
            log_path=Path("/events.jsonl"),
        )
        self.assertEqual(payload["StandardOutPath"], "/dev/null")
        self.assertEqual(payload["StandardErrorPath"], "/dev/null")
        self.assertIn("/repo/tools/recall_sync/run_autosync.py", payload["ProgramArguments"])
        self.assertEqual(
            payload["WatchPaths"], ["/collection.anki2", "/concepts.yaml"]
        )
        self.assertEqual(payload["StartInterval"], 15 * 60)
        self.assertIn("/concepts.yaml", payload["ProgramArguments"])

    def test_install_preserves_only_the_legacy_log_beside_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            runtime = root / "runtime"
            collection = root / "collection.anki2"
            concepts = root / "concepts.yaml"
            log = root / "logs/events.jsonl"
            launch_agent = root / "LaunchAgents/recall.plist"

            (repo / "tools/recall_sync").mkdir(parents=True)
            (repo / "tools/recall_sync/run_autosync.py").write_text(
                "# reviewed runner\n", encoding="utf-8"
            )
            (runtime / ".venv/bin").mkdir(parents=True)
            (runtime / ".venv/bin/python").touch()
            (runtime / ".env").write_text("private\n", encoding="utf-8")
            collection.touch()
            concepts.write_text("nodes: []\n", encoding="utf-8")
            log.parent.mkdir(parents=True)
            legacy = log.with_name("recall-autosync.log")
            legacy.write_text("old output\n", encoding="utf-8")

            backup = install_runtime.install(
                repo_root=repo,
                runtime_dir=runtime,
                collection=collection,
                concepts=concepts,
                log_path=log,
                launch_agent=launch_agent,
            )

            self.assertIsNotNone(backup)
            self.assertEqual(backup.parent, log.parent)
            self.assertFalse(legacy.exists())
            self.assertEqual(backup.read_text(encoding="utf-8"), "old output\n")
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(launch_agent.stat().st_mode), 0o600)
            with launch_agent.open("rb") as handle:
                payload = install_runtime.plistlib.load(handle)
            self.assertEqual(
                payload["ProgramArguments"][1],
                str(repo / "tools/recall_sync/run_autosync.py"),
            )


if __name__ == "__main__":
    unittest.main()

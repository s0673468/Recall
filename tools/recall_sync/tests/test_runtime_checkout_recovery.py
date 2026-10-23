from __future__ import annotations

import contextlib
import io
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import test_update_runtime as fixtures
import install_runtime
import run_autosync
import update_runtime


class InterruptedProcess(BaseException):
    """Emulate process termination without running exception cleanup."""


class CheckoutRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = fixtures.RuntimeUpdateTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.candidate = self.fixture.advance()
        self.marker = self.fixture.runtime / update_runtime.RECOVERY_MARKER
        self.original_git = update_runtime._git

    def partial_checkout(self, repo, *arguments):
        if arguments[0] == "checkout":
            self.assertTrue(self.marker.is_file())
            self.assertEqual(stat.S_IMODE(self.marker.stat().st_mode), 0o600)
            (repo / "version.txt").write_text("partially written source\n")
            (repo / "tools/recall_sync/tests/test_candidate.py").write_text("partial\n")
            raise update_runtime.UpdateError("git_command_failed")
        return self.original_git(repo, *arguments)

    def assert_restored(self) -> None:
        fixture = self.fixture
        fixture.assert_old()
        self.assertEqual(fixture.git(fixture.repo, "status", "--porcelain"), "")
        self.assertEqual(fixture.git(fixture.clone, "rev-parse", "HEAD"), fixture.old)
        self.assertEqual(fixture.git(fixture.clone, "status", "--porcelain"), "")
        self.assertEqual((fixture.runtime / ".env").read_text(), "# private state sentinel\n")
        self.assertTrue((fixture.runtime / ".venv/bin/python").is_symlink())
        self.assertFalse(self.marker.exists())

    def test_partial_checkout_restores_old_files_and_removes_partial_additions(self) -> None:
        ignored = self.fixture.repo / "local.cache"
        exclude = self.fixture.root / "fixture-ignore"
        exclude.write_text("local.cache\n")
        self.fixture.git(self.fixture.clone, "config", "core.excludesFile", str(exclude))
        ignored.write_text("unrelated ignored state\n")
        with mock.patch.object(update_runtime, "_git", side_effect=self.partial_checkout):
            with self.assertRaisesRegex(update_runtime.UpdateError, "runtime_checkout_failed"):
                self.fixture.update()
        self.assert_restored()
        self.assertEqual(ignored.read_text(), "unrelated ignored state\n")
        # The failed attempt must not strand the runtime as dirty on later runs.
        self.assertEqual(self.fixture.update(), "updated")

    def test_failure_after_head_moves_also_rolls_back(self) -> None:
        def checkout_then_fail(repo, *arguments):
            result = self.original_git(repo, *arguments)
            if arguments[0] == "checkout":
                raise update_runtime.UpdateError("git_unavailable")
            return result

        with mock.patch.object(update_runtime, "_git", side_effect=checkout_then_fail):
            with self.assertRaisesRegex(update_runtime.UpdateError, "runtime_checkout_failed"):
                self.fixture.update()
        self.assert_restored()

    def test_dirty_result_after_successful_checkout_is_rolled_back(self) -> None:
        def checkout_then_damage(repo, *arguments):
            result = self.original_git(repo, *arguments)
            if arguments[0] == "checkout":
                (repo / "version.txt").write_text("incomplete checkout\n")
            return result

        with mock.patch.object(update_runtime, "_git", side_effect=checkout_then_damage):
            with self.assertRaisesRegex(update_runtime.UpdateError, "runtime_checkout_failed"):
                self.fixture.update()
        self.assert_restored()

    def test_interrupted_checkout_recovers_before_dirty_check_fetch_or_tests(self) -> None:
        def crash(repo, *arguments):
            if arguments[0] == "checkout":
                try:
                    self.partial_checkout(repo, *arguments)
                except update_runtime.UpdateError:
                    raise InterruptedProcess()
            return self.original_git(repo, *arguments)

        with mock.patch.object(update_runtime, "_git", side_effect=crash):
            with self.assertRaises(InterruptedProcess):
                self.fixture.update()
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.fixture.git(self.fixture.repo, "rev-parse", "HEAD"), self.fixture.old)
        with mock.patch.object(update_runtime, "_git", wraps=self.original_git) as git, \
                mock.patch.object(update_runtime, "_test_candidate") as tests:
            self.assertEqual(self.fixture.update(), "recovered")
        self.assertFalse(any(call.args[1] == "fetch" for call in git.call_args_list))
        tests.assert_not_called()
        self.assert_restored()

    def test_failed_rollback_retains_marker_and_later_update_recovers(self) -> None:
        def fail_rollback(repo, *arguments):
            if arguments[0] == "reset":
                raise update_runtime.UpdateError("git_command_failed")
            return self.partial_checkout(repo, *arguments)

        with mock.patch.object(update_runtime, "_git", side_effect=fail_rollback):
            with self.assertRaisesRegex(update_runtime.UpdateError, "runtime_update_recovery_required"):
                self.fixture.update()
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.fixture.update(), "recovered")
        self.assert_restored()

    def test_marker_must_be_durable_before_checkout(self) -> None:
        with mock.patch.object(update_runtime, "_sync_directory", side_effect=OSError), \
                mock.patch.object(update_runtime, "_git", wraps=self.original_git) as git:
            with self.assertRaises(OSError):
                self.fixture.update()
        self.assertFalse(any(call.args[1] == "checkout" for call in git.call_args_list))
        self.fixture.assert_old()
        self.assertEqual(self.fixture.update(), "recovered")
        self.assert_restored()

    def test_marker_write_failure_leaves_old_runtime_unblocked(self) -> None:
        with mock.patch.object(update_runtime.os, "fsync", side_effect=OSError), \
                mock.patch.object(update_runtime, "_git", wraps=self.original_git) as git:
            with self.assertRaises(OSError):
                self.fixture.update()
        self.assertFalse(any(call.args[1] == "checkout" for call in git.call_args_list))
        self.assertEqual(list(self.fixture.runtime.glob(".runtime-update-*")), [])
        self.assert_restored()

    def test_process_interrupted_after_head_moves_recovers_previous_commit(self) -> None:
        def crash_after_checkout(repo, *arguments):
            result = self.original_git(repo, *arguments)
            if arguments[0] == "checkout":
                raise InterruptedProcess()
            return result

        with mock.patch.object(update_runtime, "_git", side_effect=crash_after_checkout):
            with self.assertRaises(InterruptedProcess):
                self.fixture.update()
        self.assertEqual(self.fixture.git(self.fixture.repo, "rev-parse", "HEAD"), self.candidate)
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.fixture.update(), "recovered")
        self.assert_restored()

    def test_success_removes_marker(self) -> None:
        self.assertEqual(self.fixture.update(), "updated")
        self.assertFalse(self.marker.exists())

    def test_invalid_or_wrong_worktree_record_never_resets_source(self) -> None:
        for record in ("{", json.dumps({
            "repo": str(self.fixture.clone), "previous": self.fixture.old,
            "candidate": self.candidate,
        })):
            with self.subTest(record=record):
                self.marker.write_text(record)
                with mock.patch.object(update_runtime, "_git") as git:
                    with self.assertRaisesRegex(update_runtime.UpdateError, "runtime_update_recovery_required"):
                        self.fixture.update()
                git.assert_not_called()
                self.assertTrue(self.marker.exists())
                self.fixture.assert_old()

    def test_cli_does_not_claim_old_head_when_recovery_is_required(self) -> None:
        self.marker.write_text("{")
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            result = install_runtime.main([
                "--update", "--repo-root", str(self.fixture.repo),
                "--runtime-dir", str(self.fixture.runtime),
                "--log", str(self.fixture.root / "events.jsonl"),
            ])
        self.assertEqual(result, 1)
        self.assertIn("runtime_update_recovery_required", output.getvalue())
        self.assertNotIn("runtime was not advanced", output.getvalue())


class AutosyncRecoveryGuardTests(unittest.TestCase):
    def test_pending_even_invalid_marker_blocks_private_reads_and_children(self) -> None:
        # This guard needs no valid source tree, private config or data fixture.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime"
            runtime.mkdir()
            marker = runtime / update_runtime.RECOVERY_MARKER
            for broken_link in (False, True):
                with self.subTest(broken_link=broken_link):
                    marker.unlink(missing_ok=True)
                    if broken_link:
                        marker.symlink_to(root / "missing")
                    else:
                        marker.write_text("incomplete recovery record")
                    loader = mock.Mock(side_effect=AssertionError("configuration read"))
                    runner = mock.Mock(side_effect=AssertionError("child executed"))
                    log = root / "events.jsonl"
                    result = run_autosync.run_once(
                        repo_root=root / "missing-source", runtime_dir=runtime,
                        collection=root / "missing-collection", concepts=root / "missing-concepts",
                        log_path=log, settle_seconds=0,
                        command_runner=runner, env_loader=loader,
                    )
                    self.assertEqual(result, 1)
                    loader.assert_not_called()
                    runner.assert_not_called()
                    event = json.loads(log.read_text().splitlines()[-1])
                    self.assertEqual(event["cause_code"], "runtime_update_recovery_required")
                    self.assertFalse((runtime / ".last_sync_mtime").exists())
                    marker.unlink()

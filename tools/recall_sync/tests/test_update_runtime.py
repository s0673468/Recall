from __future__ import annotations

import contextlib
import fcntl
import io
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install_runtime
import update_runtime


class RuntimeUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        # All repositories are disposable synthetic fixtures; no network remote
        # or developer checkout is used, including when this suite gates itself.
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = mock.patch.dict(os.environ, {
            "HOME": str(self.root), "PATH": os.defpath,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.origin = self.root / "origin"
        self.git(self.root, "init", "--initial-branch=main", str(self.origin))
        for suite in update_runtime.SUITES:
            path = self.origin / suite
            path.mkdir(parents=True)
            (path / "test_candidate.py").write_text(
                "import os, pathlib, unittest\n"
                "class Candidate(unittest.TestCase):\n"
                " def test_isolated(self):\n"
                "  self.assertFalse(pathlib.Path('.git').exists())\n"
                "  self.assertFalse(pathlib.Path('.env').exists())\n"
                "  self.assertNotIn('PRIVATE_RUNTIME_SETTING', os.environ)\n"
                "  self.assertFalse(list(pathlib.Path.home().iterdir()))\n",
                encoding="utf-8",
            )
        self.old = self.commit("Initial synthetic runtime")
        self.clone = self.root / "checkout"
        self.git(self.root, "clone", str(self.origin), str(self.clone))
        self.repo = self.root / "runtime-src"
        self.git(self.clone, "worktree", "add", "--detach", str(self.repo), self.old)
        self.runtime = self.root / "runtime-state"
        (self.runtime / ".venv/bin").mkdir(parents=True)
        (self.runtime / ".venv/bin/python").symlink_to(sys.executable)
        # A non-secret sentinel confirms runtime state is untouched.
        (self.runtime / ".env").write_text("# private state sentinel\n")

    def git(self, repo: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "core.hooksPath=/dev/null", "-C", str(repo), *arguments],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return result.stdout.strip()

    def commit(self, message: str) -> str:
        self.git(self.origin, "add", ".")
        self.git(self.origin, "commit", "--allow-empty", "-m", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def advance(self) -> str:
        (self.origin / "version.txt").write_text("new source\n")
        return self.commit("Advance synthetic main")

    def update(self) -> str:
        return update_runtime.update_runtime(repo_root=self.repo, runtime_dir=self.runtime)

    def assert_old(self) -> None:
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.old)
        self.assertFalse((self.repo / "version.txt").exists())

    def test_fast_forward_tests_candidate_and_preserves_other_checkout_and_state(self) -> None:
        candidate = self.advance()
        self.git(self.clone, "config", "fetch.prune", "true")
        self.git(self.clone, "update-ref", "refs/remotes/origin/unrelated", self.old)
        (self.clone / "unrelated.txt").write_text("unrelated local work\n")
        before = self.git(self.clone, "status", "--porcelain")
        os.environ["PRIVATE_RUNTIME_SETTING"] = "not-for-candidate-tests"
        self.assertEqual(self.update(), "updated")
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), candidate)
        self.assertEqual(self.git(self.repo, "rev-parse", "--abbrev-ref", "HEAD"), "HEAD")
        self.assertEqual(self.git(self.clone, "rev-parse", "HEAD"), self.old)
        self.assertEqual(self.git(self.clone, "status", "--porcelain"), before)
        self.assertEqual(self.git(self.clone, "rev-parse", "origin/unrelated"), self.old)
        self.assertEqual((self.runtime / ".env").read_text(), "# private state sentinel\n")
        self.assertTrue((self.runtime / ".venv/bin/python").is_symlink())
        self.assertEqual(self.git(self.repo, "status", "--porcelain"), "")

    def test_divergent_main_is_refused_before_tests(self) -> None:
        candidate = self.advance()
        self.git(self.clone, "fetch", "origin", "main")
        self.git(self.repo, "checkout", "--detach", candidate)
        self.old = candidate
        self.git(self.origin, "reset", "--hard", "HEAD~1")
        (self.origin / "divergence.txt").write_text("alternate main\n")
        self.commit("Diverge synthetic main")
        with mock.patch.object(update_runtime, "_test_candidate") as tests:
            with self.assertRaisesRegex(update_runtime.UpdateError, "non_fast_forward"):
                self.update()
        tests.assert_not_called()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), candidate)

    def test_main_moving_backwards_is_refused(self) -> None:
        candidate = self.advance()
        self.git(self.clone, "fetch", "origin", "main")
        self.git(self.repo, "checkout", "--detach", candidate)
        self.git(self.origin, "reset", "--hard", "HEAD~1")
        with self.assertRaisesRegex(update_runtime.UpdateError, "non_fast_forward"):
            self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), candidate)

    def test_either_failing_suite_keeps_old_runtime(self) -> None:
        for suite in update_runtime.SUITES:
            with self.subTest(suite=suite):
                failing = self.origin / suite / "test_failure.py"
                failing.write_text("import unittest\nclass Failure(unittest.TestCase):\n def test_failure(self): self.fail('synthetic failure')\n")
                self.commit("Add synthetic failing test")
                with self.assertRaisesRegex(update_runtime.UpdateError, "candidate_tests_failed"):
                    self.update()
                self.assert_old()
                failing.unlink()

    def test_dirty_tracked_or_untracked_runtime_is_refused_before_fetch(self) -> None:
        self.advance()
        for path in ("tools/recall_sync/tests/test_candidate.py", "untracked.txt"):
            with self.subTest(path=path):
                target = self.repo / path
                original = target.read_bytes() if target.exists() else None
                target.write_text("local work\n")
                with self.assertRaisesRegex(update_runtime.UpdateError, "dirty_runtime"):
                    self.update()
                self.assert_old()
                self.assertEqual(self.git(self.repo, "rev-parse", "origin/main"), self.old)
                self.assertEqual(target.read_text(), "local work\n")
                if original is None:
                    target.unlink()
                else:
                    target.write_bytes(original)

    def test_fetch_failure_keeps_old_runtime(self) -> None:
        self.git(self.clone, "remote", "set-url", "origin", str(self.root / "missing"))
        with self.assertRaisesRegex(update_runtime.UpdateError, "git_command_failed"):
            self.update()
        self.assert_old()

    def test_missing_candidate_suite_keeps_old_runtime(self) -> None:
        (self.origin / update_runtime.SUITES[1] / "test_candidate.py").unlink()
        self.commit("Remove synthetic candidate suite")
        with self.assertRaisesRegex(update_runtime.UpdateError, "candidate_tests_missing"):
            self.update()
        self.assert_old()

    def test_unavailable_safe_extraction_keeps_old_runtime(self) -> None:
        self.advance()
        with mock.patch.object(update_runtime.tarfile.TarFile, "extractall", side_effect=TypeError):
            with self.assertRaisesRegex(update_runtime.UpdateError, "candidate_copy_failed"):
                self.update()
        self.assert_old()

    def test_ignored_file_collision_is_not_overwritten(self) -> None:
        # Git considers ignored files clean, but they still must survive.
        (self.origin / ".gitignore").write_text("version.txt\n")
        base = self.commit("Ignore local runtime file")
        self.git(self.clone, "fetch", "origin", "main")
        self.git(self.repo, "checkout", "--detach", base)
        (self.repo / "version.txt").write_text("ignored local work\n")
        (self.origin / "version.txt").write_text("merged source\n")
        self.git(self.origin, "add", "--force", "version.txt")
        self.commit("Add conflicting source file")
        with self.assertRaisesRegex(update_runtime.UpdateError, "git_command_failed"):
            self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), base)
        self.assertEqual((self.repo / "version.txt").read_text(), "ignored local work\n")

    def test_attached_or_primary_checkout_is_refused(self) -> None:
        with self.assertRaisesRegex(update_runtime.UpdateError, "linked_worktree_required"):
            update_runtime.update_runtime(repo_root=self.clone, runtime_dir=self.runtime)
        self.git(self.repo, "checkout", "-b", "runtime-branch")
        with self.assertRaisesRegex(update_runtime.UpdateError, "detached_head_required"):
            self.update()

    def test_no_change_skips_candidate_tests(self) -> None:
        with mock.patch.object(update_runtime, "_test_candidate") as tests:
            self.assertEqual(self.update(), "current")
        tests.assert_not_called()

    def test_active_autosync_blocks_update(self) -> None:
        self.advance()
        with (self.runtime / ".autosync.lock").open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.update(), "busy")
        self.assert_old()

    def test_changes_during_tests_are_refused(self) -> None:
        self.advance()
        def edit(*_args: object) -> None:
            (self.repo / "untracked.txt").write_text("concurrent local work\n")
        with mock.patch.object(update_runtime, "_test_candidate", side_effect=edit):
            with self.assertRaisesRegex(update_runtime.UpdateError, "dirty_runtime"):
                self.update()
        self.assert_old()

    def test_clean_head_change_during_tests_is_refused(self) -> None:
        candidate = self.advance()
        def move_head(*_args: object) -> None:
            self.git(self.repo, "checkout", "--detach", candidate)
        with mock.patch.object(update_runtime, "_test_candidate", side_effect=move_head):
            with self.assertRaisesRegex(update_runtime.UpdateError, "runtime_changed_during_tests"):
                self.update()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), candidate)

    def test_checkout_uses_tested_sha_even_if_remote_ref_changes(self) -> None:
        candidate = self.advance()
        def move_ref(*_args: object) -> None:
            self.git(self.clone, "update-ref", "refs/remotes/origin/main", self.old)
        with mock.patch.object(update_runtime, "_test_candidate", side_effect=move_ref):
            self.assertEqual(self.update(), "updated")
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), candidate)

    def test_test_timeout_keeps_old_runtime(self) -> None:
        self.advance()
        original = subprocess.run
        def run(command: list[str], **kwargs: object) -> object:
            if "unittest" in command:
                raise subprocess.TimeoutExpired(command, 1)
            return original(command, **kwargs)
        with mock.patch.object(subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(update_runtime.UpdateError, "candidate_tests_unavailable"):
                self.update()
        self.assert_old()

    def test_cli_failure_reports_closed_reason_without_loading_private_env(self) -> None:
        (self.repo / "local.txt").write_text("local work\n")
        output = io.StringIO()
        log = self.root / "events.jsonl"
        with contextlib.redirect_stderr(output), mock.patch.object(
            install_runtime, "effective_concepts_path", side_effect=AssertionError("private env read")
        ):
            result = install_runtime.main([
                "--update", "--repo-root", str(self.repo),
                "--runtime-dir", str(self.runtime), "--log", str(log),
            ])
        self.assertEqual(result, 1)
        self.assertIn("dirty_runtime", output.getvalue())
        event = json.loads(log.read_text())
        self.assertEqual(event["operation"], "update_runtime")
        self.assertEqual(event["cause_code"], "dirty_runtime")
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)

    def test_cli_success_records_update_without_loading_private_env(self) -> None:
        self.advance()
        output = io.StringIO()
        log = self.root / "events.jsonl"
        with contextlib.redirect_stdout(output), mock.patch.object(
            install_runtime, "effective_concepts_path", side_effect=AssertionError("private env read")
        ):
            result = install_runtime.main([
                "--update", "--repo-root", str(self.repo),
                "--runtime-dir", str(self.runtime), "--log", str(log),
            ])
        self.assertEqual(result, 0)
        self.assertIn("updated", output.getvalue())
        self.assertEqual(json.loads(log.read_text())["cause_code"], "updated")


class UpdateInstallerTests(unittest.TestCase):
    def test_daily_job_keeps_runtime_python_and_uses_dedicated_source(self) -> None:
        payload = install_runtime.build_update_plist(
            python=Path("/state/.venv/bin/python"), repo_root=Path("/source"),
            runtime_dir=Path("/state"), log_path=Path("/events.jsonl"),
        )
        self.assertEqual(payload["StartInterval"], 86400)
        self.assertTrue(payload["RunAtLoad"])
        self.assertEqual(payload["ProgramArguments"][:3], [
            "/state/.venv/bin/python", "/source/tools/recall_sync/install_runtime.py", "--update",
        ])
        self.assertEqual(payload["StandardErrorPath"], "/dev/null")

    def test_default_source_is_runtime_instead_of_calling_checkout(self) -> None:
        self.assertEqual(install_runtime._parser().parse_args([]).repo_root,
                         Path.home() / "Code/_runtime/recall-src")

    def test_apply_installs_both_jobs_and_preview_writes_neither(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = ["--repo-root", str(root / "source"), "--runtime-dir", str(root / "state"),
                         "--launch-agent", str(root / "agents/autosync.plist")]
            with mock.patch.object(install_runtime, "effective_concepts_path", return_value=root / "concepts"), mock.patch.object(
                install_runtime, "install"
            ) as install, contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(install_runtime.main(arguments), 0)
                install.assert_not_called()
                self.assertFalse((root / "agents").exists())
                self.assertIn(install_runtime.UPDATE_LABEL, output.getvalue())
                self.assertEqual(install_runtime.main(["--apply", *arguments]), 0)
                install.assert_called_once()
            agent = root / f"agents/{install_runtime.UPDATE_LABEL}.plist"
            self.assertEqual(stat.S_IMODE(agent.stat().st_mode), 0o600)
            self.assertEqual(plistlib.loads(agent.read_bytes())["Label"], install_runtime.UPDATE_LABEL)


if __name__ == "__main__":
    unittest.main()

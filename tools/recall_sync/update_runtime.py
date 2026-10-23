"""Advance only a clean, detached runtime after isolated candidate tests pass."""

from __future__ import annotations

import fcntl
import os
import subprocess
import tarfile
import tempfile
from pathlib import Path


TIMEOUT = 20 * 60
SUITES = ("tools/recall_sync/tests", "tools/anki_revision/tests")


class UpdateError(RuntimeError):
    """A closed, non-sensitive reason why the old runtime was retained."""


def _git(repo: Path, *arguments: str) -> str:
    # Ignore repository-routing variables inherited from a calling shell.
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        result = subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false",
             "-C", str(repo), *arguments],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            check=False, timeout=TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UpdateError("git_unavailable") from exc
    if result.returncode:
        raise UpdateError("git_command_failed")
    return result.stdout.decode("utf-8").strip()


def _clean_detached_head(repo: Path) -> str:
    if not (repo / ".git").is_file():
        raise UpdateError("linked_worktree_required")
    if Path(_git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
        raise UpdateError("worktree_root_required")
    if _git(repo, "rev-parse", "--abbrev-ref", "HEAD") != "HEAD":
        raise UpdateError("detached_head_required")
    if _git(repo, "status", "--porcelain", "--untracked-files=all"):
        raise UpdateError("dirty_runtime")
    return _git(repo, "rev-parse", "HEAD")


def _test_candidate(repo: Path, candidate: str, python: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="recall-runtime-check-") as directory:
        temporary = Path(directory)
        archive = temporary / "candidate.tar"
        _git(repo, "archive", "--format=tar", f"--output={archive}", candidate)
        source = temporary / "source"
        source.mkdir()
        try:
            with tarfile.open(archive) as handle:
                handle.extractall(source, filter="data")
        except (tarfile.TarError, OSError, TypeError) as exc:
            raise UpdateError("candidate_copy_failed") from exc
        home = temporary / "home"
        home.mkdir()
        # No runtime .env, inherited service configuration, user home or Git
        # metadata enters the candidate tests. Reuse only the existing Python.
        environment = {
            "PATH": os.defpath, "HOME": str(home), "TMPDIR": str(temporary),
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
        }
        for suite in SUITES:
            if not list((source / suite).glob("test_*.py")):
                raise UpdateError("candidate_tests_missing")
            try:
                result = subprocess.run(
                    [str(python), "-I", "-B", "-m", "unittest", "discover",
                     "-s", suite, "-p", "test_*.py"],
                    cwd=source, env=environment, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, check=False, timeout=TIMEOUT,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise UpdateError("candidate_tests_unavailable") from exc
            if result.returncode:
                raise UpdateError("candidate_tests_failed")


def update_runtime(*, repo_root: Path, runtime_dir: Path) -> str:
    """Fetch main and test its exact SHA, preserving all other working trees.

    The same nonblocking lock as run_autosync prevents moving source while a
    sync is using it. No branch, other worktree, secrets or virtualenv is moved.
    Git's shared origin/main ref may advance; checkout uses the tested SHA.
    """
    repo = repo_root.expanduser().resolve()
    runtime = runtime_dir.expanduser().resolve()
    if runtime.is_relative_to(repo) or repo.is_relative_to(runtime):
        raise UpdateError("separate_runtime_state_required")
    python = runtime / ".venv/bin/python"
    if not python.is_file():
        raise UpdateError("runtime_python_missing")
    lock_path = runtime / ".autosync.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        lock_path.chmod(0o600)
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return "busy"
        previous = _clean_detached_head(repo)
        _git(repo, "fetch", "--no-tags", "--no-prune", "--no-recurse-submodules", "--no-auto-gc",
             "--no-write-fetch-head", "origin",
             "+refs/heads/main:refs/remotes/origin/main")
        candidate = _git(repo, "rev-parse", "refs/remotes/origin/main^{commit}")
        if previous == candidate:
            return "current"
        try:
            _git(repo, "merge-base", "--is-ancestor", previous, candidate)
        except UpdateError as exc:
            raise UpdateError("non_fast_forward") from exc
        _test_candidate(repo, candidate, python)
        if _clean_detached_head(repo) != previous:
            raise UpdateError("runtime_changed_during_tests")
        # Never force, overwrite ignored local files, recurse into submodules,
        # run checkout hooks, or resolve a moving ref after validation.
        _git(repo, "checkout", "--detach", "--no-overwrite-ignore", candidate)
        return "updated"

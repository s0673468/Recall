#!/usr/bin/env python3
"""Install Recall's reviewed owner-only launchd autosync runtime."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence


LABEL = "com.german.recall-autosync"
UPDATE_LABEL = "com.german.recall-runtime-update"


def build_update_plist(
    *, python: Path, repo_root: Path, runtime_dir: Path, log_path: Path
) -> dict[str, object]:
    return {
        "Label": UPDATE_LABEL,
        "ProgramArguments": [
            str(python), str(repo_root / "tools/recall_sync/install_runtime.py"),
            "--update", "--repo-root", str(repo_root),
            "--runtime-dir", str(runtime_dir), "--log", str(log_path),
        ],
        "StartInterval": 24 * 60 * 60,
        "RunAtLoad": True,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }


def effective_concepts_path(*, runtime_dir: Path, configured: Path) -> Path:
    """Resolve the documented private-env override used by the runner."""
    env_path = runtime_dir / ".env"
    if not env_path.exists():
        return configured.expanduser().resolve()
    try:
        from dotenv import dotenv_values
    except ImportError as exc:
        raise RuntimeError(
            "python-dotenv is missing; run the installer with the runtime Python"
        ) from exc
    value = dotenv_values(env_path).get("METIS_CONCEPTS_YAML")
    return Path(value or configured).expanduser().resolve()


def build_plist(
    *,
    python: Path,
    runner: Path,
    repo_root: Path,
    runtime_dir: Path,
    collection: Path,
    concepts: Path,
    log_path: Path,
) -> dict[str, object]:
    return {
        "Label": LABEL,
        "ProgramArguments": [
            str(python),
            str(runner),
            "--repo-root",
            str(repo_root),
            "--runtime-dir",
            str(runtime_dir),
            "--collection",
            str(collection),
            "--concepts",
            str(concepts),
            "--log",
            str(log_path),
        ],
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
        "ThrottleInterval": 30,
        "StartInterval": 15 * 60,
        "WatchPaths": [str(collection), str(concepts)],
    }


def _atomic_plist(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            plistlib.dump(payload, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def install(
    *,
    repo_root: Path,
    runtime_dir: Path,
    collection: Path,
    concepts: Path,
    log_path: Path,
    launch_agent: Path,
) -> Path | None:
    env_path = runtime_dir / ".env"
    python = runtime_dir / ".venv/bin/python"
    runner = repo_root / "tools/recall_sync/run_autosync.py"
    for path, description in (
        (env_path, "runtime .env"),
        (python, "runtime Python"),
        (runner, "reviewed autosync runner"),
        (collection, "Anki collection"),
        (concepts, "METIS concepts"),
    ):
        if not path.exists():
            raise FileNotFoundError(f"{description} is missing: {path}")

    runtime_dir.chmod(0o700)
    env_path.chmod(0o600)
    for private_file in (runtime_dir / ".last_sync_mtime", runtime_dir / ".autosync.lock"):
        if private_file.exists():
            private_file.chmod(0o600)

    legacy_backup: Path | None = None
    old_log = log_path.with_name("recall-autosync.log")
    if old_log.exists() and old_log.stat().st_size:
        suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        legacy_backup = old_log.with_name(f"{old_log.stem}.legacy-{suffix}.log")
        shutil.move(old_log, legacy_backup)
        legacy_backup.chmod(0o600)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.touch(mode=0o600, exist_ok=True)
    log_path.chmod(0o600)

    payload = build_plist(
        python=python,
        runner=runner,
        repo_root=repo_root,
        runtime_dir=runtime_dir,
        collection=collection,
        concepts=concepts,
        log_path=log_path,
    )
    _atomic_plist(launch_agent, payload)
    return legacy_backup


def _parser() -> argparse.ArgumentParser:
    home = Path.home()
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write both launchd jobs")
    mode.add_argument("--update", action="store_true", help="test and fast-forward the runtime")
    parser.add_argument("--repo-root", type=Path, default=home / "Code/_runtime/recall-src")
    parser.add_argument(
        "--runtime-dir", type=Path, default=home / "Code/_runtime/recall-anki-sync"
    )
    parser.add_argument(
        "--collection",
        type=Path,
        default=home / "Library/Application Support/Anki2/User 1/collection.anki2",
    )
    parser.add_argument(
        "--concepts",
        type=Path,
        default=home / "Code/METIS/graph/concepts.yaml",
    )
    parser.add_argument(
        "--log", type=Path, default=home / "Library/Logs/recall-autosync.jsonl"
    )
    parser.add_argument(
        "--launch-agent",
        type=Path,
        default=home / f"Library/LaunchAgents/{LABEL}.plist",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    repo_root = args.repo_root.expanduser().resolve()
    runtime_dir = args.runtime_dir.expanduser().resolve()
    log_path = args.log.expanduser().resolve()
    if args.update:
        # This path never loads the private .env or reads sync sources.
        from update_runtime import UpdateError, update_runtime
        from run_autosync import _event, append_event

        failure = None
        try:
            status = update_runtime(repo_root=repo_root, runtime_dir=runtime_dir)
        except UpdateError as exc:
            failure = str(exc)
        except (OSError, ValueError, EOFError):
            failure = "runtime_update_unavailable"
        if failure:
            print(f"runtime update refused: {failure}; check recovery status before retrying", file=sys.stderr)
        else:
            print(f"runtime update: {status}")
        try:
            append_event(log_path, _event(
                operation="update_runtime", outcome="failed" if failure else "succeeded",
                cause_code=failure or status, retryable=bool(failure) or status == "busy",
                run_id=str(uuid.uuid4()),
            ))
        except OSError:
            print("runtime update receipt unavailable", file=sys.stderr)
            return 1
        return 1 if failure else 0
    concepts = effective_concepts_path(
        runtime_dir=runtime_dir,
        configured=args.concepts,
    )
    payload = build_plist(
        python=runtime_dir / ".venv/bin/python",
        runner=repo_root / "tools/recall_sync/run_autosync.py",
        repo_root=repo_root,
        runtime_dir=runtime_dir,
        collection=args.collection.expanduser().resolve(),
        concepts=concepts,
        log_path=args.log.expanduser().resolve(),
    )
    if not args.apply:
        print(plistlib.dumps(payload, sort_keys=True).decode("utf-8"), end="")
        print(plistlib.dumps(build_update_plist(
            python=runtime_dir / ".venv/bin/python", repo_root=repo_root,
            runtime_dir=runtime_dir, log_path=log_path,
        ), sort_keys=True).decode("utf-8"), end="")
        return 0
    backup = install(
        repo_root=repo_root,
        runtime_dir=runtime_dir,
        collection=args.collection.expanduser().resolve(),
        concepts=concepts,
        log_path=args.log.expanduser().resolve(),
        launch_agent=args.launch_agent.expanduser().resolve(),
    )
    print(f"installed {args.launch_agent.expanduser().resolve()}")
    update_agent = args.launch_agent.expanduser().resolve().with_name(f"{UPDATE_LABEL}.plist")
    _atomic_plist(update_agent, build_update_plist(
        python=runtime_dir / ".venv/bin/python", repo_root=repo_root,
        runtime_dir=runtime_dir, log_path=log_path,
    ))
    print(f"installed {update_agent}")
    if backup is not None:
        print(f"preserved legacy log at {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

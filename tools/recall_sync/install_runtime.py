#!/usr/bin/env python3
"""Install Recall's reviewed owner-only launchd autosync runtime."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence


LABEL = "com.german.recall-autosync"


def build_plist(
    *,
    python: Path,
    runner: Path,
    repo_root: Path,
    runtime_dir: Path,
    collection: Path,
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
            "--log",
            str(log_path),
        ],
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
        "ThrottleInterval": 30,
        "WatchPaths": [str(collection)],
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
        log_path=log_path,
    )
    _atomic_plist(launch_agent, payload)
    return legacy_backup


def _parser() -> argparse.ArgumentParser:
    home = Path.home()
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="write the launchd files")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--runtime-dir", type=Path, default=home / "Code/_runtime/recall-anki-sync"
    )
    parser.add_argument(
        "--collection",
        type=Path,
        default=home / "Library/Application Support/Anki2/User 1/collection.anki2",
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
    payload = build_plist(
        python=(args.runtime_dir / ".venv/bin/python").expanduser().resolve(),
        runner=repo_root / "tools/recall_sync/run_autosync.py",
        repo_root=repo_root,
        runtime_dir=args.runtime_dir.expanduser().resolve(),
        collection=args.collection.expanduser().resolve(),
        log_path=args.log.expanduser().resolve(),
    )
    if not args.apply:
        print(plistlib.dumps(payload, sort_keys=True).decode("utf-8"), end="")
        return 0
    backup = install(
        repo_root=repo_root,
        runtime_dir=args.runtime_dir.expanduser().resolve(),
        collection=args.collection.expanduser().resolve(),
        log_path=args.log.expanduser().resolve(),
        launch_agent=args.launch_agent.expanduser().resolve(),
    )
    print(f"installed {args.launch_agent.expanduser().resolve()}")
    if backup is not None:
        print(f"preserved legacy log at {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run the private Anki-to-Recall sync with bounded canonical receipts.

This is the reviewed source for the launchd job. Secrets remain in the
owner-only runtime ``.env``; subprocess output is deliberately discarded so
card text, endpoints, and credentials can never enter the persistent log.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, Sequence


SCHEMA = "operational-event/v2"
MAX_EVENTS = 100
MAX_LOG_BYTES = 64 * 1024
COMMAND_TIMEOUT_SECONDS = 20 * 60
REQUIRED_ENV = ("SUPABASE_URL", "SUPABASE_SERVICE_KEY")


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _event(
    *,
    operation: str,
    outcome: str,
    cause_code: str,
    retryable: bool,
    run_id: str,
) -> dict[str, object]:
    return {
        "schema": SCHEMA,
        "timestamp": _timestamp(),
        "level": "info" if outcome == "succeeded" else "error",
        "project": "recall",
        "component": "anki_sync",
        "operation": operation,
        "outcome": outcome,
        "cause_code": cause_code,
        "retryable": retryable,
        "run_id": run_id,
    }


def _is_canonical(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    return (
        value.get("schema") == SCHEMA
        and value.get("project") == "recall"
        and value.get("component") == "anki_sync"
        and value.get("level") in {"info", "error"}
        and value.get("outcome") in {"succeeded", "failed"}
        and isinstance(value.get("timestamp"), str)
        and isinstance(value.get("operation"), str)
        and isinstance(value.get("cause_code"), str)
        and isinstance(value.get("retryable"), bool)
        and isinstance(value.get("run_id"), str)
    )


def _read_events(path: Path) -> list[dict[str, object]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (FileNotFoundError, OSError, UnicodeError):
        return []
    events: list[dict[str, object]] = []
    for line in lines[-MAX_EVENTS:]:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if _is_canonical(value):
            events.append(value)
    return events


def append_event(path: Path, event: dict[str, object]) -> None:
    """Atomically append one event while keeping the file private and bounded."""
    if not _is_canonical(event):
        raise ValueError("refusing to persist a non-canonical operational event")
    path.parent.mkdir(parents=True, exist_ok=True)
    events = [*_read_events(path), event][-MAX_EVENTS:]
    encoded = [
        json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"
        for value in events
    ]
    while encoded and len("".join(encoded).encode("utf-8")) > MAX_LOG_BYTES:
        encoded.pop(0)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.writelines(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def load_runtime_env(path: Path) -> dict[str, str]:
    try:
        from dotenv import dotenv_values
    except ImportError as exc:  # pragma: no cover - owned runtime installs it
        raise RuntimeError("python-dotenv is missing from the Recall runtime") from exc
    values = dotenv_values(path)
    return {
        str(key): str(value)
        for key, value in values.items()
        if key and value is not None
    }


def _write_stamp(path: Path, value: str) -> None:
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"{value}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def _read_stamp(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError, UnicodeError):
        return ""


def run_once(
    *,
    repo_root: Path,
    runtime_dir: Path,
    collection: Path,
    concepts: Path,
    log_path: Path,
    settle_seconds: float = 8,
    command_runner: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
    env_loader: Callable[[Path], Mapping[str, str]] = load_runtime_env,
) -> int:
    runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime_dir.chmod(0o700)
    lock_path = runtime_dir / ".autosync.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        lock_path.chmod(0o600)
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0

        if settle_seconds:
            time.sleep(settle_seconds)
        run_id = str(uuid.uuid4())
        try:
            source_revision = (
                f"{collection.stat().st_mtime_ns}:"
                f"{concepts.stat().st_mtime_ns}"
            )
        except OSError:
            append_event(
                log_path,
                _event(
                    operation="read_sources",
                    outcome="failed",
                    cause_code="sync_source_unavailable",
                    retryable=True,
                    run_id=run_id,
                ),
            )
            return 1

        stamp_path = runtime_dir / ".last_sync_mtime"
        if _read_stamp(stamp_path) == source_revision:
            return 0

        try:
            runtime_values = dict(env_loader(runtime_dir / ".env"))
        except Exception:
            append_event(
                log_path,
                _event(
                    operation="load_configuration",
                    outcome="failed",
                    cause_code="runtime_config_unavailable",
                    retryable=False,
                    run_id=run_id,
                ),
            )
            return 1
        if any(not runtime_values.get(key) for key in REQUIRED_ENV):
            append_event(
                log_path,
                _event(
                    operation="load_configuration",
                    outcome="failed",
                    cause_code="runtime_config_incomplete",
                    retryable=False,
                    run_id=run_id,
                ),
            )
            return 1

        child_env = dict(os.environ)
        child_env.update(runtime_values)
        child_env["METIS_CONCEPTS_YAML"] = str(concepts)
        commands: Sequence[tuple[str, Path]] = (
            ("import_collection", repo_root / "tools/anki_revision/import_to_supabase.py"),
            ("sync_concepts", repo_root / "tools/recall_sync/sync_concept_nodes.py"),
        )
        results: dict[str, int] = {}
        for operation, script in commands:
            if not script.is_file():
                return_code = 127
            else:
                try:
                    completed = command_runner(
                        [sys.executable, str(script)],
                        cwd=runtime_dir,
                        env=child_env,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        check=False,
                        timeout=COMMAND_TIMEOUT_SECONDS,
                    )
                    return_code = completed.returncode
                except subprocess.TimeoutExpired:
                    return_code = 124
                except OSError:
                    return_code = 127
            results[operation] = return_code
            append_event(
                log_path,
                _event(
                    operation=operation,
                    outcome="succeeded" if return_code == 0 else "failed",
                    cause_code="none" if return_code == 0 else f"{operation}_failed",
                    retryable=return_code != 0,
                    run_id=run_id,
                ),
            )

        succeeded = all(return_code == 0 for return_code in results.values())
        if succeeded:
            _write_stamp(stamp_path, source_revision)
        return 0 if succeeded else 1


def _parser() -> argparse.ArgumentParser:
    home = Path.home()
    parser = argparse.ArgumentParser()
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
        "--concepts",
        type=Path,
        default=home / "Code/METIS/graph/concepts.yaml",
    )
    parser.add_argument(
        "--log", type=Path, default=home / "Library/Logs/recall-autosync.jsonl"
    )
    parser.add_argument("--settle-seconds", type=float, default=8)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    return run_once(
        repo_root=args.repo_root.resolve(),
        runtime_dir=args.runtime_dir.expanduser().resolve(),
        collection=args.collection.expanduser().resolve(),
        concepts=args.concepts.expanduser().resolve(),
        log_path=args.log.expanduser().resolve(),
        settle_seconds=args.settle_seconds,
    )


if __name__ == "__main__":
    raise SystemExit(main())

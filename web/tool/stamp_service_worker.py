#!/usr/bin/env python3
"""Finish a Recall Pages build without Flutter's retired PWA flags."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import tempfile


PLACEHOLDER = "__SW_VERSION__"
COMMIT_RE = re.compile(r"[0-9a-f]{40}")


def finish_build(output: Path, version: str) -> None:
    if COMMIT_RE.fullmatch(version) is None:
        raise ValueError("service-worker version must be a full lowercase commit SHA")

    worker = output / "sw.js"
    source = worker.read_text(encoding="utf-8")
    if source.count(PLACEHOLDER) != 1:
        raise ValueError("sw.js must contain exactly one unstamped version placeholder")

    output.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=output,
        prefix=".sw.js.",
        text=True,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(source.replace(PLACEHOLDER, version))
        os.replace(temporary, worker)
    finally:
        temporary.unlink(missing_ok=True)

    # Current Flutter emits an empty compatibility tombstone. Recall registers
    # its own versioned worker, so uploading the tombstone only invites drift.
    (output / "flutter_service_worker.js").unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    finish_build(args.output, args.version)


if __name__ == "__main__":
    main()

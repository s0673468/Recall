#!/usr/bin/env python3
"""Install or check the repo-canonical anki-revision skill for Codex."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import shutil
from pathlib import Path


TARGETS = (
    Path.home() / ".codex" / "skills" / "anki-revision",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mirror_is_current(target: Path, expected: str) -> bool:
    skill_file = target / "SKILL.md"
    return (
        skill_file.is_file()
        and not skill_file.is_symlink()
        and digest(skill_file) == expected
        and sorted(path.name for path in target.iterdir()) == ["SKILL.md"]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).with_name("SKILL.md")
    expected = digest(source)
    drift: list[str] = []
    for target in TARGETS:
        skill_file = target / "SKILL.md"
        if args.check:
            if not mirror_is_current(target, expected):
                drift.append(str(target))
            continue
        if mirror_is_current(target, expected):
            print(f"already current {skill_file}")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        staging = target.parent / f".{target.name}.stage.{os.getpid()}"
        staging.mkdir(mode=0o755)
        shutil.copyfile(source, staging / "SKILL.md")
        os.chmod(staging / "SKILL.md", 0o644)
        if target.exists():
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            retired_root = target.parent / ".retired"
            retired_root.mkdir(mode=0o700, exist_ok=True)
            backup = retired_root / f"{target.name}-{stamp}-{os.getpid()}"
            target.replace(backup)
            print(f"retired previous mirror to {backup}")
        staging.replace(target)
        print(f"installed {skill_file}")
    if drift:
        print("installed skill drift:")
        for path in drift:
            print(f"  {path}")
        return 1
    if args.check:
        print("installed Codex skill matches repo-canonical source")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

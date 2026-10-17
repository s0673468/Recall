#!/usr/bin/env python3
"""Split the Flutter test files into deterministic, file-level CI shards.

`flutter test --total-shards` slices the tests inside every file, so each shard
still compiles and loads all of them. Most of the suite's time is that
per-file compile, so the hosted CI shards by whole file instead.

Every `test/**/*_test.dart` file lands in exactly one shard, the same discovery
that a bare `flutter test` uses. Files are placed largest-source-first onto the
lightest shard, which keeps the shards close without a timing file to maintain.
"""
import argparse
from pathlib import Path
import sys


def test_files(root):
    return sorted(p.relative_to(root).as_posix() for p in (root / "test").rglob("*_test.dart"))


def shards(root, total):
    files = test_files(root)
    if total < 1:
        raise ValueError("total must be positive")
    if total > len(files):
        # An empty shard would make `flutter test` run every file.
        raise ValueError(f"{total} shards for {len(files)} test files leaves a shard empty")
    groups = [[] for _ in range(total)]
    weights = [0] * total
    for name in sorted(files, key=lambda name: (-(root / name).stat().st_size, name)):
        lightest = min(range(total), key=lambda index: (weights[index], index))
        groups[lightest].append(name)
        weights[lightest] += (root / name).stat().st_size
    return [sorted(group) for group in groups]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--total", type=int, required=True, help="number of shards")
    parser.add_argument("--index", type=int, required=True, help="zero-based shard to print")
    args = parser.parse_args(argv)
    if not 0 <= args.index < args.total:
        parser.error("index must be in [0, total)")
    root = Path(__file__).resolve().parents[1]
    try:
        groups = shards(root, args.total)
    except ValueError as error:
        parser.error(str(error))
    sys.stdout.write("".join(name + "\n" for name in groups[args.index]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

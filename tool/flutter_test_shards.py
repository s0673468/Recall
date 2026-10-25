#!/usr/bin/env python3
"""Split the Flutter test files into deterministic, file-level CI shards.

`flutter test --total-shards` slices the tests inside every file, so each shard
still compiles and loads all of them. Most of the suite's time is that
per-file compile, so the hosted CI shards by whole file instead.

Every `test/**/*_test.dart` file lands in exactly one shard, the same discovery
that a bare `flutter test` uses. Files are placed highest-cost-first onto the
lightest shard. Measured loading/body times take precedence when their test
source hash and SDK version still match; other files use a source-size estimate.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys


def test_files(root):
    return sorted(p.relative_to(root).as_posix() for p in (root / "test").rglob("*_test.dart"))


def file_costs(root, files, use_timings=True):
    sizes = {name: max(1, (root / name).stat().st_size) for name in files}
    manifest = root / "tool/flutter_test_timings.json"
    if not use_timings or not manifest.exists():
        return sizes
    try:
        data = json.loads(manifest.read_text())
        if data["schema"] != "recall-flutter-test-timings/v1":
            raise ValueError("unknown timing schema")
        if data["flutter"] != (root / ".flutter-version").read_text().strip():
            return sizes
        measured = {}
        for name, row in data["files"].items():
            if name not in sizes:
                continue  # Removed/renamed files never affect discovery.
            seconds = row["seconds"]
            if (type(seconds) not in (int, float) or not math.isfinite(seconds)
                    or seconds <= 0):
                raise ValueError(f"invalid duration for {name}")
            if hashlib.sha256((root / name).read_bytes()).hexdigest() == row["sha256"]:
                measured[name] = seconds
    except (KeyError, TypeError, AttributeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid Flutter timing manifest: {error}") from error
    if not measured:
        return sizes
    # Keep new/edited tests in comparable units without trusting a stale time.
    seconds_per_byte = statistics.median(measured[name] / sizes[name] for name in measured)
    return {name: measured.get(name, size * seconds_per_byte) for name, size in sizes.items()}


def shards(root, total, use_timings=True):
    files = test_files(root)
    if total < 1:
        raise ValueError("total must be positive")
    if total > len(files):
        # An empty shard would make `flutter test` run every file.
        raise ValueError(f"{total} shards for {len(files)} test files leaves a shard empty")
    groups = [[] for _ in range(total)]
    weights = [0] * total
    costs = file_costs(root, files, use_timings=use_timings)
    for name in sorted(files, key=lambda name: (-costs[name], name)):
        lightest = min(range(total), key=lambda index: (weights[index], index))
        groups[lightest].append(name)
        weights[lightest] += costs[name]
    # Start expensive files early so their compilation/body work overlaps the
    # remaining files instead of becoming a long tail on the four workers.
    if use_timings:
        return [sorted(group, key=lambda name: (-costs[name], name)) for group in groups]
    return [sorted(group) for group in groups]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--total", type=int, required=True, help="number of shards")
    parser.add_argument("--index", type=int, required=True, help="zero-based shard to print")
    parser.add_argument("--no-timings", action="store_true", help="use source-size weights for a baseline comparison")
    args = parser.parse_args(argv)
    if not 0 <= args.index < args.total:
        parser.error("index must be in [0, total)")
    root = Path(__file__).resolve().parents[1]
    try:
        groups = shards(root, args.total, use_timings=not args.no_timings)
    except ValueError as error:
        parser.error(str(error))
    sys.stdout.write("".join(name + "\n" for name in groups[args.index]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

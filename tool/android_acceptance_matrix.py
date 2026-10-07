#!/usr/bin/env python3
"""Initialize the private Android acceptance queue; never executes device work."""

import argparse
import datetime as dt
import itertools
import json
import os
from pathlib import Path
import socket


FLOWS = (
    "first_launch", "sign_in", "reveal", "rate", "undo", "flag", "hide",
    "catch_up", "keep_going", "read_primers", "stats", "settings",
    "widget_add_refresh", "reminder_fire", "deep_link",
    "upgrade_queued_outbox", "offline_reconnect", "process_death_review",
)
PROFILES = (
    "small_phone", "large_phone", "fold_folded", "fold_unfolded",
    "fold_posture_change", "tablet",
)


def matrix():
    """Stable IDs identify the complete Cartesian contract, not executed tests."""
    axes = itertools.product(
        FLOWS, PROFILES, ("light", "dark"), (1.0, 1.3, 2.0),
        (False, True), ("en", "pt"),
    )
    for number, (flow, profile, theme, font, talkback, locale) in enumerate(axes, 1):
        yield {
            "schema": 1,
            "id": f"A5-{number:04d}",
            "flow": flow,
            "profile": profile,
            "theme": theme,
            "font_scale": font,
            "talkback": talkback,
            "locale": locale,
            "status": "pending",
            "attempts": [],
            "evidence": [],
            "independent_verification": None,
        }


def initialize(destination, *, root_thread_id, source_sha, source_host):
    """Create a new private folder exclusively; never reset an existing campaign."""
    destination = Path(destination)
    # Parent must already exist: a typo must not silently create another tree.
    destination.mkdir(mode=0o700)
    os.chmod(destination, 0o700)
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    rows = list(matrix())
    usage = {
        "schema": 1,
        "observed_at": now,
        "root_thread_id": root_thread_id,
        "source_host": source_host,
        "sessions": [],
        "input_tokens": None,
        "output_tokens": None,
        "total_tokens": None,
        "cached_input_tokens_subset": None,
        "coverage": "Unknown until authoritative root and descendant telemetry is read.",
        "accounting_rule": "Unique session cumulative high-water totals once; cached input is a subset.",
        "per_item": {},
    }
    state = (
        "# Recall Android acceptance\n\n"
        f"Checkpoint: {now}\nSource: {source_sha}\nHost: {source_host}\n"
        f"Root chat: {root_thread_id}\n\n"
        f"{len(rows)} cases pending; 0 executed, 0 verified.\n"
        "Queue generation is not device acceptance. No PR, merge, or APK delivery is established.\n"
        "Builds and emulator runs require fleet admission and an isolated invented-data fixture.\n"
        "No production login, card-content changes, or FSRS changes.\n"
        "36 hours is a checkpoint boundary; remaining authorized work stays open.\n"
    )
    files = {
        "QUEUE.jsonl": "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
        "USAGE.json": json.dumps(usage, indent=2) + "\n",
        "STATE.md": state,
        "MORNING.md": state,
    }
    for name, content in files.items():
        descriptor = os.open(destination / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
    return len(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--root-thread-id", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    if len(args.source_sha) != 40 or any(c not in "0123456789abcdef" for c in args.source_sha):
        parser.error("--source-sha must be the full lowercase Git commit SHA")
    count = initialize(
        args.destination, root_thread_id=args.root_thread_id,
        source_sha=args.source_sha, source_host=socket.gethostname(),
    )
    print(f"Initialized {count} pending cases in {args.destination}")


if __name__ == "__main__":
    main()

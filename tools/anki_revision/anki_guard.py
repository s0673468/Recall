#!/usr/bin/env python3
"""Pre-flight safety gate for any job that will write the live collection.

Two jobs:
  1. Refuse to proceed if the Anki desktop app is running. SQLite writes while
     Anki holds the collection open corrupt it; Anki must be fully closed.
  2. Take a timestamped backup so any apply is trivially reversible.

Note the `voicebanking` filter: macOS runs a `voicebankingd` daemon whose name
contains the substring "anki", so a naive process match flags it as Anki. We
drop those lines explicitly.

    python3 anki_guard.py --desc revise_ml          # check + backup
    python3 anki_guard.py --check-only              # just the running check

Exit code 1 if Anki is running (or a requested backup fails); 0 when safe.
"""

import argparse
import os
import shutil
import subprocess
import sys
from datetime import datetime

import anki_common as ac


def anki_processes():
    try:
        out = subprocess.run(
            ["pgrep", "-fil", "anki"], capture_output=True, text=True
        ).stdout
    except FileNotFoundError:
        return []
    hits = []
    for line in out.splitlines():
        low = line.lower()
        if "voicebanking" in low:
            continue  # macOS daemon, false match on the "anki" substring
        if "anki_guard" in low or "pgrep" in low:
            continue  # don't match ourselves
        if "anki" in low:
            hits.append(line.strip())
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=ac.LIVE_DB)
    ap.add_argument("--desc", default="job", help="slug used in the backup filename")
    ap.add_argument("--check-only", action="store_true", help="skip the backup")
    args = ap.parse_args()

    running = anki_processes()
    if running:
        print("=== UNSAFE: Anki appears to be running — close it before applying ===")
        for line in running:
            print("  ", line)
        sys.exit(1)
    print("ok: Anki is not running")

    if not os.path.exists(args.db):
        print(f"=== ERROR: collection not found at {args.db} ===")
        sys.exit(1)

    if args.check_only:
        sys.exit(0)

    os.makedirs(ac.BACKUP_DIR, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    dest = os.path.join(
        ac.BACKUP_DIR, f"collection_backup_before_{args.desc}_{stamp}.anki2"
    )
    try:
        shutil.copy2(args.db, dest)
    except OSError as e:
        print(f"=== ERROR: backup failed: {e} ===")
        sys.exit(1)
    size_mb = os.path.getsize(dest) / 1e6
    print(f"backed up -> {dest}  ({size_mb:.1f} MB)")
    print("BACKUP_PATH=" + dest)  # easy to grep from the workflow


if __name__ == "__main__":
    main()

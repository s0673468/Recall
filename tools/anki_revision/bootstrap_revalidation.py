#!/usr/bin/env python3
"""Build a reviewed marker manifest for an already-applied semantic job.

This is a read-only bootstrap seam. It selects retained existing notes whose
compiled record was an edit or split with ``score_before <= 3``, verifies their
exact live content and stable identity, and emits a guarded tag-mutation
manifest. It never changes Anki.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

import anki_apply
import anki_common as ac


def build_manifest(
    *, db_path: Path, job_dir: Path, revision_at: str
) -> list[dict[str, object]]:
    marker = anki_apply._revision_marker(revision_at)
    _, records = anki_apply.load_job(job_dir)
    selected: list[dict[str, object]] = []
    seen: set[int] = set()
    connection = ac.connect(str(db_path), ro=True)
    try:
        anki_apply.require_collection(connection, "bootstrap database")
        for record in records:
            if record.get("action") not in {"edit", "split"}:
                continue
            score_before = record.get("score_before")
            if not isinstance(score_before, (int, float)) or score_before > 3:
                continue
            nid = record.get("nid")
            if not isinstance(nid, int) or nid in seen:
                raise anki_apply.ApplyError(
                    "bootstrap records need unique existing nids"
                )
            seen.add(nid)
            row = connection.execute(
                "SELECT guid,mid,tags,flds FROM notes WHERE id=?", (nid,)
            ).fetchone()
            if row is None:
                raise anki_apply.ApplyError(f"bootstrap nid {nid} is not live")
            expected = record["cards"][0]
            if row[3] != expected["front"] + ac.FSEP + expected["back"]:
                raise anki_apply.ApplyError(
                    f"bootstrap nid {nid} content does not match compiled job"
                )
            current = str(row[2] or "").split()
            remove = [
                tag for tag in current if tag.startswith(anki_apply.REVALIDATE_PREFIX)
            ]
            selected.append(
                {
                    "nid": nid,
                    "guid": row[0],
                    "mid": row[1],
                    "add": [marker],
                    "remove": remove,
                    "expected_original_tags": current,
                    "selection": "edit-or-split-score-before-lte-3",
                }
            )
    finally:
        connection.close()
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--job-dir", type=Path, required=True)
    parser.add_argument("--revision-at", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        rows = build_manifest(
            db_path=args.db, job_dir=args.job_dir, revision_at=args.revision_at
        )
    except (anki_apply.ApplyError, sqlite3.Error) as error:
        parser.exit(1, f"bootstrap rejected: {error}\n")
    if args.out.exists():
        parser.exit(1, f"bootstrap output already exists: {args.out}\n")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": "recall.revalidation-bootstrap/v1",
        "revision_at": args.revision_at,
        "selection": "action-in-edit-split-and-score-before-lte-3",
        "mutations": rows,
    }
    args.out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"bootstrap material markers={len(rows)} -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

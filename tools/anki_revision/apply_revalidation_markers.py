#!/usr/bin/env python3
"""Guarded tag-only apply for a revalidation bootstrap artifact.

Dry-run is the default. Apply requires an exact independent backup, the exact
dry-run receipt, and literal confirmation. The writer changes only ``notes.tags``
plus Anki sync metadata; content, cards, decks, and scheduling are read back
unchanged before commit.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sqlite3
import time
from pathlib import Path

import anki_apply
import anki_common as ac


CONFIRMATION = "APPLY_REVALIDATION_MARKERS"
SCHEMA = "recall.revalidation-bootstrap/v1"


def load_artifact(path: Path) -> dict[str, object]:
    payload = anki_apply._read_json(path)
    if not isinstance(payload, dict) or payload.get("schema") != SCHEMA:
        raise anki_apply.ApplyError(f"artifact is not {SCHEMA}")
    marker = anki_apply._revision_marker(payload.get("revision_at"))
    mutations = payload.get("mutations")
    if not isinstance(mutations, list):
        raise anki_apply.ApplyError("bootstrap mutations must be a list")
    seen: set[int] = set()
    for index, row in enumerate(mutations):
        if not isinstance(row, dict):
            raise anki_apply.ApplyError(f"mutations[{index}] must be an object")
        nid = row.get("nid")
        if not isinstance(nid, int) or nid <= 0 or nid in seen:
            raise anki_apply.ApplyError(f"mutations[{index}] has invalid/duplicate nid")
        seen.add(nid)
        if not isinstance(row.get("guid"), str) or not isinstance(row.get("mid"), int):
            raise anki_apply.ApplyError(f"mutations[{index}] lacks stable identity")
        if row.get("add") != [marker]:
            raise anki_apply.ApplyError(f"mutations[{index}] does not add exact marker")
        expected = row.get("expected_original_tags")
        if not isinstance(expected, list) or not all(
            isinstance(tag, str) and tag and not any(c.isspace() for c in tag)
            for tag in expected
        ):
            raise anki_apply.ApplyError(f"mutations[{index}] has invalid expected tags")
        remove = row.get("remove")
        expected_remove = [
            tag for tag in expected if tag.startswith(anki_apply.REVALIDATE_PREFIX)
        ]
        if remove != expected_remove:
            raise anki_apply.ApplyError(
                f"mutations[{index}] stale-marker removal differs"
            )
    return payload


def artifact_digest(payload: dict[str, object]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def desired_tags(expected: list[str], marker: str) -> str:
    retained = [
        tag for tag in expected if not tag.startswith(anki_apply.REVALIDATE_PREFIX)
    ]
    retained.append(marker)
    return " " + " ".join(dict.fromkeys(retained)) + " "


def execute(
    *,
    db_path: Path,
    artifact_path: Path,
    commit: bool,
    backup_path: Path | None = None,
    dry_run_receipt: Path | None = None,
) -> tuple[dict[str, object], Path]:
    artifact = load_artifact(artifact_path)
    mutations = artifact["mutations"]
    marker = anki_apply._revision_marker(artifact["revision_at"])
    digest = artifact_digest(artifact)
    connection = ac.connect(str(db_path))
    try:
        if commit:
            connection.execute("BEGIN IMMEDIATE")
        anki_apply.require_collection(connection, "live database")
        before_digest = anki_apply.collection_digest(connection)
        card_rows_before = {
            int(nid): connection.execute(
                "SELECT * FROM cards WHERE nid=? ORDER BY id", (int(nid),)
            ).fetchall()
            for nid in (row["nid"] for row in mutations)
        }
        fields_before: dict[int, str] = {}
        desired: dict[int, str] = {}
        current: dict[int, str] = {}
        for row in mutations:
            nid = int(row["nid"])
            live = connection.execute(
                "SELECT guid,mid,tags,flds FROM notes WHERE id=?", (nid,)
            ).fetchone()
            if live is None or (live[0], live[1]) != (row["guid"], row["mid"]):
                raise anki_apply.ApplyError(f"nid {nid}: stable identity differs")
            tokens = str(live[2] or "").split()
            if tokens != row["expected_original_tags"]:
                raise anki_apply.ApplyError(
                    f"nid {nid}: live tags differ from artifact"
                )
            current[nid] = str(live[2] or "")
            fields_before[nid] = str(live[3])
            desired[nid] = desired_tags(tokens, marker)

        receipt: dict[str, object] = {
            "schema": "anki-revalidation-receipt/v1",
            "kind": "apply" if commit else "dry_run",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "artifact_digest": digest,
            "collection_digest_before": before_digest,
            "revision_at": artifact["revision_at"],
            "marker": marker,
            "mutations": len(mutations),
            "changed": sum(desired[nid] != current[nid] for nid in desired),
        }
        if not commit:
            path = anki_apply._write_receipt(
                artifact_path.parent / "receipts", "revalidation-dry-run", receipt
            )
            connection.rollback()
            return receipt, path

        if backup_path is None or dry_run_receipt is None:
            raise anki_apply.ApplyError("apply requires --backup and --dry-run-receipt")
        prior = anki_apply._load_dry_receipt(dry_run_receipt)
        for key, expected in {
            "artifact_digest": digest,
            "collection_digest_before": before_digest,
            "marker": marker,
        }.items():
            if prior.get(key) != expected:
                raise anki_apply.ApplyError(f"dry-run receipt {key} differs")
        anki_apply.verify_backup(connection, backup_path, set(current), db_path)
        now_s = int(time.time())
        for nid, tags in desired.items():
            if tags == current[nid]:
                continue
            updated = connection.execute(
                "UPDATE notes SET tags=?,mod=?,usn=-1 WHERE id=? AND tags=?",
                (tags, now_s, nid, current[nid]),
            )
            if updated.rowcount != 1:
                raise anki_apply.ApplyError(f"nid {nid}: tag compare-and-swap failed")
        connection.execute(
            "INSERT OR IGNORE INTO tags (tag,usn,collapsed,config) VALUES (?,-1,0,NULL)",
            (marker,),
        )
        connection.execute("UPDATE col SET mod=?", (int(time.time() * 1000),))
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise anki_apply.ApplyError("post-write integrity check failed")
        for nid, expected_tags in desired.items():
            after = connection.execute(
                "SELECT tags,flds FROM notes WHERE id=?", (nid,)
            ).fetchone()
            cards_after = connection.execute(
                "SELECT * FROM cards WHERE nid=? ORDER BY id", (nid,)
            ).fetchall()
            if after != (expected_tags, fields_before[nid]):
                raise anki_apply.ApplyError(f"nid {nid}: exact note readback failed")
            if cards_after != card_rows_before[nid]:
                raise anki_apply.ApplyError(f"nid {nid}: scheduling/deck row changed")
        connection.commit()
        after = ac.connect(str(db_path), ro=True)
        try:
            receipt["collection_digest_after"] = anki_apply.collection_digest(after)
        finally:
            after.close()
        receipt.update(
            {"backup": str(backup_path), "dry_run_receipt": str(dry_run_receipt)}
        )
        path = anki_apply._write_receipt(
            artifact_path.parent / "receipts", "revalidation-apply", receipt
        )
        return receipt, path
    except Exception:
        if commit:
            connection.rollback()
        raise
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--dry-run-receipt", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmation")
    args = parser.parse_args()
    if args.apply and args.confirmation != CONFIRMATION:
        parser.error(f"--apply requires --confirmation {CONFIRMATION}")
    try:
        result, receipt = execute(
            db_path=args.db,
            artifact_path=args.artifact,
            commit=args.apply,
            backup_path=args.backup,
            dry_run_receipt=args.dry_run_receipt,
        )
    except (anki_apply.ApplyError, sqlite3.Error) as error:
        parser.exit(1, f"revalidation marker apply rejected: {error}\n")
    print(json.dumps({"summary": result, "receipt": str(receipt)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

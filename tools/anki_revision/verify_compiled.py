#!/usr/bin/env python3
"""Exact readback of an applied compiled Anki contract.

This verifier is read-only and content-agnostic. It proves that retained notes,
deletions, additions, tags, material-change markers, structure, and the immutable
apply receipt agree with the compiled job.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

import anki_apply
import anki_common as ac


class VerifyError(ValueError):
    """Raised when live readback differs from the compiled contract."""


def verify(
    *,
    db_path: Path,
    job_dir: Path,
    apply_receipt: Path,
    tag: str,
    require_concept_tags: bool = False,
) -> dict[str, object]:
    manifest, records = anki_apply.load_job(job_dir)
    existing, adds, marker = anki_apply.validate_records(manifest, records)
    receipt = anki_apply._read_json(apply_receipt)
    if not isinstance(receipt, dict) or receipt.get("kind") != "apply":
        raise VerifyError("receipt is not an apply receipt")
    digest = anki_apply.changeset_digest(
        manifest, records, tag, receipt.get("handoff_evidence")
    )
    if receipt.get("changeset_digest") != digest or receipt.get("tag") != tag:
        raise VerifyError("apply receipt does not match job or tag")

    connection = ac.connect(str(db_path), ro=True)
    try:
        anki_apply.require_collection(connection, "readback database")
        rows = {
            int(nid): {
                "flds": str(flds),
                "tags": str(tags or ""),
                "did": int(did),
            }
            for nid, flds, tags, did in connection.execute(
                "SELECT n.id,n.flds,n.tags,c.did FROM notes n "
                "JOIN cards c ON c.nid=n.id GROUP BY n.id"
            )
        }
        decks = {
            int(did): str(name).replace(ac.FSEP, "::")
            for did, name in connection.execute("SELECT id,name FROM decks")
        }
        for nid, record in existing.items():
            if record["action"] == "delete":
                if nid in rows:
                    raise VerifyError(f"deleted nid {nid} is still present")
                continue
            row = rows.get(nid)
            if row is None:
                raise VerifyError(f"retained nid {nid} is missing")
            if record["action"] in {"edit", "split"}:
                first = record["cards"][0]
                if row["flds"] != first["front"] + ac.FSEP + first["back"]:
                    raise VerifyError(f"nid {nid} content does not match compiled card")
                tags = row["tags"].split()
                if not set(first.get("tags_add", [])).issubset(tags) or tag not in tags:
                    raise VerifyError(f"nid {nid} is missing compiled tags")
                if record["revision_kind"] == "material" and marker not in tags:
                    raise VerifyError(f"nid {nid} is missing material-change marker")

        expected_additions = [
            (
                str(record["deck"]),
                card["front"],
                card["back"],
                card.get("tags_add", []),
                False,
            )
            for record in adds
            for card in record["cards"]
        ]
        for record in existing.values():
            if record["action"] == "split":
                expected_additions.extend(
                    (
                        "__parent__",
                        card["front"],
                        card["back"],
                        card.get("tags_add", []),
                        record["revision_kind"] == "material",
                    )
                    for card in record["cards"][1:]
                )
        logged = receipt.get("added")
        if not isinstance(logged, list) or len(logged) != len(expected_additions):
            raise VerifyError("apply receipt addition count differs from compiled job")
        for expected, actual in zip(expected_additions, logged, strict=True):
            deck, front, back, tags_add, material = expected
            if not isinstance(actual, dict) or not isinstance(actual.get("nid"), int):
                raise VerifyError(
                    "apply receipt contains an invalid added-note identity"
                )
            row = rows.get(actual["nid"])
            if row is None or row["flds"] != front + ac.FSEP + back:
                raise VerifyError(f"added nid {actual['nid']} content readback failed")
            if deck != "__parent__" and decks[row["did"]] != deck:
                raise VerifyError(f"added nid {actual['nid']} deck readback failed")
            tokens = row["tags"].split()
            if tag not in tokens or not set(tags_add).issubset(tokens):
                raise VerifyError(f"added nid {actual['nid']} tag readback failed")
            if material and marker not in tokens:
                raise VerifyError(
                    f"split child nid {actual['nid']} lacks material marker"
                )

        if require_concept_tags:
            for nid, row in rows.items():
                nodes = [
                    token for token in row["tags"].split() if token.startswith("node::")
                ]
                if len(nodes) != 1 or nodes[0] == "node::none":
                    raise VerifyError(
                        f"nid {nid} does not have exactly one real concept tag"
                    )
        orphan_cards = connection.execute(
            "SELECT COUNT(*) FROM cards WHERE nid NOT IN (SELECT id FROM notes)"
        ).fetchone()[0]
        noteless_notes = connection.execute(
            "SELECT COUNT(*) FROM notes WHERE id NOT IN (SELECT nid FROM cards)"
        ).fetchone()[0]
        empty_front = sum(
            not ac.strip_html(str(flds).split(ac.FSEP)[0]).strip()
            for (flds,) in connection.execute("SELECT flds FROM notes")
        )
        note_count = len(rows)
        expected_count = receipt.get("expected_note_count_after")
        if (
            orphan_cards
            or noteless_notes
            or empty_front
            or note_count != expected_count
        ):
            raise VerifyError(
                "structural readback failed: "
                f"orphans={orphan_cards} noteless={noteless_notes} "
                f"empty_front={empty_front} notes={note_count} expected={expected_count}"
            )
    finally:
        connection.close()
    return {
        "status": "PASS",
        "notes": note_count,
        "existing_contract_notes": len(existing),
        "added_notes": len(logged),
        "concept_tags_checked": require_concept_tags,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--job-dir", type=Path, required=True)
    parser.add_argument("--apply-receipt", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--require-concept-tags", action="store_true")
    args = parser.parse_args()
    try:
        result = verify(
            db_path=args.db,
            job_dir=args.job_dir,
            apply_receipt=args.apply_receipt,
            tag=args.tag,
            require_concept_tags=args.require_concept_tags,
        )
    except (VerifyError, anki_apply.ApplyError, sqlite3.Error) as error:
        parser.exit(1, f"compiled readback failed: {error}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Guarded deterministic Anki changeset writer.

The command is a dry run unless ``--apply`` is present. A real apply requires
an immutable receipt from an earlier dry run, an independent exact backup, and
the literal confirmation ``APPLY_ANKI_CHANGESET``. Existing card rows are never
rewritten, so decks and scheduling survive content edits.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import sqlite3
import time
from pathlib import Path

import anki_common as ac


APPLY_CONFIRMATION = "APPLY_ANKI_CHANGESET"
REVALIDATE_PREFIX = "content_revalidate::"
REVISION_AT_FORMAT = "%Y%m%dT%H%M%SZ"
REQUIRED_ANKI_TABLES = {"cards", "col", "decks", "graves", "notes", "notetypes", "tags"}
HANDOFF_SCHEMA = "recall.card-handoff/v1"
HANDOFF_RESOLUTION_SCHEMA = "recall.card-handoff-resolution/v1"
NODE_OUTCOMES = {"assigned-existing", "proposed-new"}


class ApplyError(ValueError):
    """Raised when a changeset cannot be proved safe to apply."""


def _read_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ApplyError(f"could not read {path}: {error}") from error


def _revision_marker(value: object) -> str:
    if not isinstance(value, str):
        raise ApplyError("material changes require manifest revision_at")
    try:
        parsed = dt.datetime.strptime(value, REVISION_AT_FORMAT)
    except ValueError as error:
        raise ApplyError("manifest revision_at must be UTC YYYYMMDDTHHMMSSZ") from error
    if parsed.strftime(REVISION_AT_FORMAT) != value:
        raise ApplyError("manifest revision_at is not canonical")
    return REVALIDATE_PREFIX + value


def load_job(job_dir: Path) -> tuple[dict[str, object], list[dict[str, object]]]:
    manifest = _read_json(job_dir / "manifest.json")
    if not isinstance(manifest, dict):
        raise ApplyError("manifest.json must be an object")
    files = sorted((job_dir / "verified").glob("batch_*.json"))
    if not files:
        raise ApplyError("no verified/batch_*.json files found")
    records: list[dict[str, object]] = []
    for path in files:
        payload = _read_json(path)
        if not isinstance(payload, list):
            raise ApplyError(f"{path.name} must contain a JSON list")
        for index, record in enumerate(payload):
            if not isinstance(record, dict):
                raise ApplyError(f"{path.name}[{index}] must be an object")
            records.append(record)
    return manifest, records


def validate_handoff(
    job_dir: Path,
    records: list[dict[str, object]],
    tag: str,
    resolution_path: Path | None,
) -> dict[str, object] | None:
    """Validate an external card-proposal handoff and consumer evidence."""
    candidates = [job_dir / "handoff.json", job_dir / "verified" / "handoff.json"]
    handoff_path = next((path for path in candidates if path.is_file()), None)
    if handoff_path is None:
        if resolution_path is not None:
            raise ApplyError("handoff resolution was supplied without handoff.json")
        return None
    handoff = _read_json(handoff_path)
    if not isinstance(handoff, dict) or handoff.get("schema") != HANDOFF_SCHEMA:
        raise ApplyError(f"{handoff_path} is not {HANDOFF_SCHEMA}")
    add_count = sum(
        len(record.get("cards", []))
        for record in records
        if record.get("action") == "add"
    )
    if handoff.get("card_count") != add_count or handoff.get("pass_tag") != tag:
        raise ApplyError("handoff card_count or pass_tag does not match the changeset")
    checks = handoff.get("checks")
    if not isinstance(checks, list):
        raise ApplyError("handoff checks must be a list")
    by_id = {check.get("id"): check for check in checks if isinstance(check, dict)}
    if set(by_id) != {"golden-standard", "duplicate-search", "concept-node-ownership"}:
        raise ApplyError("handoff does not contain the three required checks")
    if any(check.get("required") is not True for check in by_id.values()):
        raise ApplyError("all handoff checks must be required")
    golden = by_id["golden-standard"]
    if (
        golden.get("path") != "docs/card-golden-standard.md"
        or golden.get("version") != "current-at-apply"
    ):
        raise ApplyError("handoff does not require Recall's current golden standard")
    if by_id["duplicate-search"].get("scope") != "full-catalog":
        raise ApplyError("handoff duplicate search is not full-catalog")
    if resolution_path is None:
        raise ApplyError("external handoff requires --handoff-resolution")
    resolution = _read_json(resolution_path)
    if (
        not isinstance(resolution, dict)
        or resolution.get("schema") != HANDOFF_RESOLUTION_SCHEMA
    ):
        raise ApplyError(f"handoff resolution is not {HANDOFF_RESOLUTION_SCHEMA}")
    results = resolution.get("checks")
    if not isinstance(results, dict):
        raise ApplyError("handoff resolution checks must be an object")
    for check_id in by_id:
        result = results.get(check_id)
        if not isinstance(result, dict) or result.get("status") != "passed":
            raise ApplyError(f"handoff check {check_id} is not passed")
    duplicate = results["duplicate-search"]
    if duplicate.get("scope") != "full-catalog" or not duplicate.get("catalog_digest"):
        raise ApplyError("duplicate-search evidence lacks full-catalog digest")
    node = results["concept-node-ownership"]
    if node.get("outcome") not in NODE_OUTCOMES:
        raise ApplyError("concept-node ownership outcome is invalid")
    standard_path = (
        Path(__file__).resolve().parents[2] / "docs" / "card-golden-standard.md"
    )
    standard_sha = hashlib.sha256(standard_path.read_bytes()).hexdigest()
    if results["golden-standard"].get("sha256") != standard_sha:
        raise ApplyError("golden-standard evidence is stale at apply time")
    evidence = {
        "handoff_sha256": hashlib.sha256(handoff_path.read_bytes()).hexdigest(),
        "resolution_sha256": hashlib.sha256(resolution_path.read_bytes()).hexdigest(),
        "golden_standard_sha256": standard_sha,
        "node_outcome": node["outcome"],
        "catalog_digest": duplicate["catalog_digest"],
    }
    return evidence


def validate_records(
    manifest: dict[str, object], records: list[dict[str, object]]
) -> tuple[dict[int, dict[str, object]], list[dict[str, object]], str | None]:
    existing: dict[int, dict[str, object]] = {}
    adds: list[dict[str, object]] = []
    has_material = False
    for index, record in enumerate(records):
        action = record.get("action")
        if action not in {"keep", "edit", "split", "delete", "add"}:
            raise ApplyError(f"records[{index}].action is invalid")
        cards = record.get("cards")
        if not isinstance(cards, list):
            raise ApplyError(f"records[{index}].cards must be a list")
        expected_counts = {
            "keep": lambda n: n == 1,
            "edit": lambda n: n == 1,
            "split": lambda n: n >= 2,
            "delete": lambda n: n == 0,
            "add": lambda n: n >= 1,
        }
        if not expected_counts[str(action)](len(cards)):
            raise ApplyError(f"records[{index}] action/card count mismatch")
        for card_index, card in enumerate(cards):
            if not isinstance(card, dict):
                raise ApplyError(
                    f"records[{index}].cards[{card_index}] must be an object"
                )
            for field in ("front", "back"):
                if not isinstance(card.get(field), str) or not card[field].strip():
                    raise ApplyError(
                        f"records[{index}].cards[{card_index}].{field} must be non-empty"
                    )
            tags = card.get("tags_add", [])
            if not isinstance(tags, list) or not all(
                isinstance(tag, str) and tag and not any(c.isspace() for c in tag)
                for tag in tags
            ):
                raise ApplyError(
                    f"records[{index}].cards[{card_index}].tags_add is invalid"
                )
        if action in {"edit", "split"}:
            kind = record.get("revision_kind")
            if kind not in {"wording", "material"}:
                raise ApplyError(
                    f"records[{index}].revision_kind must be wording or material"
                )
            has_material = has_material or kind == "material"
        elif "revision_kind" in record:
            raise ApplyError(
                f"records[{index}].revision_kind is only valid for edit/split"
            )

        nid = record.get("nid")
        if action == "add":
            if nid not in (None, 0):
                raise ApplyError(f"records[{index}] add must not name an existing nid")
            if not isinstance(record.get("deck"), str) or not record["deck"]:
                raise ApplyError(f"records[{index}] add requires deck")
            adds.append(record)
        else:
            if not isinstance(nid, int) or nid <= 0:
                raise ApplyError(f"records[{index}].nid must be a positive integer")
            if nid in existing:
                raise ApplyError(f"duplicate nid {nid}")
            existing[nid] = record

    mode = manifest.get("mode", "revise")
    if mode in {"revise", "dedup", "garden"}:
        nids = manifest.get("nids")
        if not isinstance(nids, list) or not all(isinstance(nid, int) for nid in nids):
            raise ApplyError("manifest.nids must be an integer list")
        if len(nids) != len(set(nids)):
            raise ApplyError("manifest.nids contains duplicates")
        if set(nids) != set(existing):
            missing = sorted(set(nids) - set(existing))[:5]
            extra = sorted(set(existing) - set(nids))[:5]
            raise ApplyError(
                f"changeset coverage mismatch: missing={missing} extra={extra}"
            )

    marker = _revision_marker(manifest.get("revision_at")) if has_material else None
    return existing, adds, marker


def _tables(connection: sqlite3.Connection) -> set[str]:
    return {
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }


def require_collection(connection: sqlite3.Connection, label: str) -> None:
    missing = sorted(REQUIRED_ANKI_TABLES - _tables(connection))
    if missing:
        raise ApplyError(
            f"{label} is not a complete Anki collection; missing {missing}"
        )
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise ApplyError(f"{label} integrity check failed: {integrity}")
    if connection.execute("SELECT COUNT(*) FROM col").fetchone()[0] != 1:
        raise ApplyError(f"{label} must contain exactly one collection row")


def collection_digest(connection: sqlite3.Connection) -> str:
    """Hash every logical collection row, independent of SQLite page layout."""
    require_collection(connection, "collection")
    digest = hashlib.sha256()
    for table in sorted(REQUIRED_ANKI_TABLES):
        columns = [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]
        if not columns:
            raise ApplyError(f"collection table {table} has no columns")
        order = ",".join(f'"{column}"' for column in columns)
        digest.update(table.encode())
        for row in connection.execute(f'SELECT * FROM "{table}" ORDER BY {order}'):
            digest.update(repr(tuple(row)).encode("utf-8"))
            digest.update(b"\n")
    return digest.hexdigest()


def _stable_note_identities(
    connection: sqlite3.Connection, nids: set[int]
) -> dict[int, tuple[object, object]]:
    if not nids:
        return {}
    placeholders = ",".join("?" for _ in nids)
    rows = connection.execute(
        f"SELECT id, guid, mid FROM notes WHERE id IN ({placeholders})",
        tuple(sorted(nids)),
    )
    return {int(nid): (guid, mid) for nid, guid, mid in rows}


def verify_backup(
    live: sqlite3.Connection, backup_path: Path, nids: set[int], db_path: Path
) -> None:
    if (
        not backup_path.is_file()
        or backup_path.is_symlink()
        or backup_path.stat().st_size == 0
    ):
        raise ApplyError(
            f"backup is missing, empty, symlinked, or not regular: {backup_path}"
        )
    try:
        if os.path.samefile(backup_path, db_path):
            raise ApplyError("backup must be independent from the live database")
    except OSError as error:
        raise ApplyError(f"could not compare backup and database: {error}") from error
    backup = ac.connect(str(backup_path), ro=True)
    try:
        require_collection(backup, "backup")
        if collection_digest(backup) != collection_digest(live):
            raise ApplyError(
                "backup is not an exact logical copy of the live collection"
            )
        live_ids = _stable_note_identities(live, nids)
        backup_ids = _stable_note_identities(backup, nids)
        if live_ids != backup_ids or set(live_ids) != nids:
            raise ApplyError("backup stable note identities do not match the changeset")
    finally:
        backup.close()


def changeset_digest(
    manifest: dict[str, object],
    records: list[dict[str, object]],
    tag: str,
    handoff_evidence: dict[str, object] | None = None,
) -> str:
    payload = {
        "manifest": manifest,
        "records": records,
        "tag": tag,
        "handoff_evidence": handoff_evidence,
    }
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _write_receipt(receipts_dir: Path, kind: str, payload: dict[str, object]) -> Path:
    receipts_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        receipts_dir.chmod(0o700)
    except OSError:
        pass
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    subject_digest = payload.get("changeset_digest") or payload.get("artifact_digest")
    if not isinstance(subject_digest, str) or len(subject_digest) < 12:
        raise ApplyError("receipt payload lacks a subject digest")
    path = receipts_dir / f"{kind}-{subject_digest[:12]}-{stamp}.json"
    encoded = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(encoded)
    return path


def _load_dry_receipt(path: Path) -> dict[str, object]:
    if not path.is_file() or path.is_symlink():
        raise ApplyError("--dry-run-receipt must be a regular immutable receipt")
    receipt = _read_json(path)
    if not isinstance(receipt, dict) or receipt.get("kind") != "dry_run":
        raise ApplyError("--dry-run-receipt is not a dry-run receipt")
    return receipt


def _replace_revalidation_marker(tags: str, marker: str) -> str:
    tokens = [tag for tag in tags.split() if not tag.startswith(REVALIDATE_PREFIX)]
    tokens.append(marker)
    return " " + " ".join(dict.fromkeys(tokens)) + " "


def _merged_tags(
    original: str, additions: list[str], pass_tag: str, marker: str | None
) -> str:
    tags = ac.merge_tags(original, additions, pass_tag)
    return _replace_revalidation_marker(tags, marker) if marker else tags


def _summary(
    existing: dict[int, dict[str, object]], adds: list[dict[str, object]]
) -> dict[str, int]:
    counts = {action: 0 for action in ("keep", "edit", "split", "delete", "add")}
    for record in existing.values():
        counts[str(record["action"])] += 1
    counts["add"] = sum(len(record["cards"]) for record in adds)
    counts["new_notes"] = counts["add"] + sum(
        len(record["cards"]) - 1
        for record in existing.values()
        if record["action"] == "split"
    )
    return counts


def execute_job(
    *,
    job_dir: Path,
    db_path: Path,
    tag: str,
    commit: bool,
    backup_path: Path | None = None,
    dry_run_receipt: Path | None = None,
    handoff_resolution: Path | None = None,
) -> tuple[dict[str, object], Path]:
    manifest, records = load_job(job_dir)
    existing, adds, marker = validate_records(manifest, records)
    handoff_evidence = validate_handoff(job_dir, records, tag, handoff_resolution)
    digest = changeset_digest(manifest, records, tag, handoff_evidence)
    if not db_path.is_file() or db_path.is_symlink():
        raise ApplyError(f"database is missing, symlinked, or not regular: {db_path}")
    connection = ac.connect(str(db_path))
    try:
        if commit:
            connection.execute("BEGIN IMMEDIATE")
        require_collection(connection, "live database")
        before_digest = collection_digest(connection)
        existing_rows = {
            int(nid): {
                "guid": guid,
                "mid": mid,
                "tags": str(tags or ""),
                "flds": flds,
                "did": int(did),
            }
            for nid, guid, mid, tags, flds, did in connection.execute(
                "SELECT n.id,n.guid,n.mid,n.tags,n.flds,c.did FROM notes n "
                "JOIN cards c ON c.nid=n.id GROUP BY n.id"
            )
        }
        missing = sorted(set(existing) - set(existing_rows))
        if missing:
            raise ApplyError(
                f"changeset notes are missing from collection: {missing[:5]}"
            )
        for nid, record in existing.items():
            if record["action"] == "keep":
                card = record["cards"][0]
                expected_fields = card["front"] + ac.FSEP + card["back"]
                if existing_rows[nid]["flds"] != expected_fields:
                    raise ApplyError(
                        f"nid {nid}: keep does not match live content exactly"
                    )
        deck_ids = ac.deck_name_to_id(connection)
        unknown = sorted({str(r["deck"]) for r in adds} - set(deck_ids))
        if unknown:
            raise ApplyError(f"adds target unknown decks: {unknown}")

        if commit:
            if backup_path is None:
                raise ApplyError("--backup is required when applying")
            if dry_run_receipt is None:
                raise ApplyError("--dry-run-receipt is required when applying")
            receipt = _load_dry_receipt(dry_run_receipt)
            expected_receipt = {
                "changeset_digest": digest,
                "collection_digest_before": before_digest,
                "tag": tag,
            }
            for key, expected_value in expected_receipt.items():
                if receipt.get(key) != expected_value:
                    raise ApplyError(
                        f"dry-run receipt {key} does not match current apply"
                    )
            verify_backup(connection, backup_path, set(existing), db_path)

        counts = _summary(existing, adds)
        note_count_before = connection.execute("SELECT COUNT(*) FROM notes").fetchone()[
            0
        ]
        expected_note_count_after = (
            note_count_before - counts["delete"] + counts["new_notes"]
        )
        base_receipt: dict[str, object] = {
            "schema": "anki-revision-receipt/v1",
            "kind": "apply" if commit else "dry_run",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "changeset_digest": digest,
            "collection_digest_before": before_digest,
            "tag": tag,
            "revision_at": manifest.get("revision_at"),
            "counts": counts,
            "note_count_before": note_count_before,
            "expected_note_count_after": expected_note_count_after,
            "handoff_evidence": handoff_evidence,
        }
        if not commit:
            path = _write_receipt(job_dir / "receipts", "dry-run", base_receipt)
            connection.rollback()
            return base_receipt, path

        assert backup_path is not None and dry_run_receipt is not None
        now_s = int(time.time())
        seed = max(
            int(time.time() * 1000),
            connection.execute(
                "SELECT MAX(value) FROM (SELECT COALESCE(MAX(id),0) value FROM notes "
                "UNION ALL SELECT COALESCE(MAX(id),0) FROM cards)"
            ).fetchone()[0]
            + 1_000_000,
        )
        new_due = connection.execute(
            "SELECT COALESCE(MAX(due),0) FROM cards WHERE type=0"
        ).fetchone()[0]
        basic_mid = ac.basic_mid(connection)
        added: list[dict[str, object]] = []
        original_card_rows: dict[int, list[tuple[object, ...]]] = {
            nid: connection.execute(
                "SELECT * FROM cards WHERE nid=? ORDER BY id", (nid,)
            ).fetchall()
            for nid in existing
        }

        def insert(
            front: str, back: str, did: int, mid: int, tags: list[str], material: bool
        ) -> int:
            nonlocal seed, new_due
            seed += 1
            nid, cid = seed, seed + 500_000
            new_due += 1
            applied_marker = marker if material else None
            connection.execute(
                "INSERT INTO notes (id,guid,mid,mod,usn,tags,flds,sfld,csum,flags,data) "
                "VALUES (?,?,?,?,-1,?,?,?,?,0,'')",
                (
                    nid,
                    ac.guid(),
                    mid,
                    now_s,
                    _merged_tags("", tags, tag, applied_marker),
                    front + ac.FSEP + back,
                    ac.strip_html(front),
                    ac.csum(front),
                ),
            )
            connection.execute(
                "INSERT INTO cards (id,nid,did,ord,mod,usn,type,queue,due,ivl,factor,reps,lapses,left,odue,odid,flags,data) "
                "VALUES (?,?,?,0,?,-1,0,0,?,0,0,0,0,0,0,0,0,'{}')",
                (cid, nid, did, now_s, new_due),
            )
            return nid

        for nid, record in existing.items():
            action = str(record["action"])
            original = existing_rows[nid]
            cards = record["cards"]
            if action == "keep":
                continue
            if action == "delete":
                for (cid,) in connection.execute(
                    "SELECT id FROM cards WHERE nid=?", (nid,)
                ).fetchall():
                    connection.execute(
                        "INSERT OR REPLACE INTO graves (oid,type,usn) VALUES (?,0,-1)",
                        (cid,),
                    )
                connection.execute(
                    "INSERT OR REPLACE INTO graves (oid,type,usn) VALUES (?,1,-1)",
                    (nid,),
                )
                connection.execute("DELETE FROM cards WHERE nid=?", (nid,))
                connection.execute("DELETE FROM notes WHERE id=?", (nid,))
                continue
            first = cards[0]
            material = record["revision_kind"] == "material"
            updated_tags = _merged_tags(
                original["tags"],
                first.get("tags_add", []),
                tag,
                marker if material else None,
            )
            connection.execute(
                "UPDATE notes SET flds=?,sfld=?,csum=?,tags=?,mod=?,usn=-1 WHERE id=?",
                (
                    first["front"] + ac.FSEP + first["back"],
                    ac.strip_html(first["front"]),
                    ac.csum(first["front"]),
                    updated_tags,
                    now_s,
                    nid,
                ),
            )
            if action == "split":
                for child in cards[1:]:
                    child_nid = insert(
                        child["front"],
                        child["back"],
                        original["did"],
                        original["mid"],
                        child.get("tags_add", []),
                        material,
                    )
                    added.append(
                        {
                            "nid": child_nid,
                            "deck": original["did"],
                            "front": child["front"],
                            "back": child["back"],
                        }
                    )

        for record in adds:
            for card in record["cards"]:
                added_nid = insert(
                    card["front"],
                    card["back"],
                    deck_ids[str(record["deck"])],
                    basic_mid,
                    card.get("tags_add", []),
                    False,
                )
                added.append(
                    {
                        "nid": added_nid,
                        "deck": record["deck"],
                        "front": card["front"],
                        "back": card["back"],
                    }
                )

        connection.execute(
            "INSERT OR IGNORE INTO tags (tag,usn,collapsed,config) VALUES (?,-1,0,NULL)",
            (tag,),
        )
        if marker:
            connection.execute(
                "INSERT OR IGNORE INTO tags (tag,usn,collapsed,config) VALUES (?,-1,0,NULL)",
                (marker,),
            )
        connection.execute("UPDATE col SET mod=?", (int(time.time() * 1000),))
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise ApplyError(f"post-apply integrity check failed: {integrity}")
        for nid, record in existing.items():
            if record["action"] in {"keep", "edit"}:
                after_cards = connection.execute(
                    "SELECT * FROM cards WHERE nid=? ORDER BY id", (nid,)
                ).fetchall()
                if after_cards != original_card_rows[nid]:
                    raise ApplyError(f"nid {nid}: card scheduling or deck row changed")
            if record["action"] in {"edit", "split", "keep"}:
                row = connection.execute(
                    "SELECT guid,mid FROM notes WHERE id=?", (nid,)
                ).fetchone()
                if row != (existing_rows[nid]["guid"], existing_rows[nid]["mid"]):
                    raise ApplyError(f"nid {nid}: stable note identity changed")
        actual_note_count = connection.execute("SELECT COUNT(*) FROM notes").fetchone()[
            0
        ]
        if actual_note_count != expected_note_count_after:
            raise ApplyError(
                f"post-apply note count {actual_note_count} != {expected_note_count_after}"
            )
        connection.commit()
        after_ro = ac.connect(str(db_path), ro=True)
        try:
            after_digest = collection_digest(after_ro)
        finally:
            after_ro.close()
        base_receipt.update(
            {
                "backup": str(backup_path),
                "dry_run_receipt": str(dry_run_receipt),
                "collection_digest_after": after_digest,
                "integrity": integrity,
                "added": added,
            }
        )
        path = _write_receipt(job_dir / "receipts", "apply", base_receipt)
        return base_receipt, path
    except Exception:
        if commit:
            connection.rollback()
        raise
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", required=True)
    parser.add_argument("--db", type=Path, default=Path(ac.LIVE_DB))
    parser.add_argument("--root", type=Path, default=Path(ac.ROOT))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--dry-run-receipt", type=Path)
    parser.add_argument("--handoff-resolution", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmation")
    args = parser.parse_args()
    if args.apply and args.confirmation != APPLY_CONFIRMATION:
        parser.error(f"--apply requires --confirmation {APPLY_CONFIRMATION}")
    try:
        summary, receipt = execute_job(
            job_dir=ac.job_dir(str(args.root), args.job),
            db_path=args.db,
            tag=args.tag,
            commit=args.apply,
            backup_path=args.backup,
            dry_run_receipt=args.dry_run_receipt,
            handoff_resolution=args.handoff_resolution,
        )
    except (ApplyError, sqlite3.Error) as error:
        parser.exit(1, f"Anki changeset rejected: {error}\n")
    print(
        json.dumps(
            {"summary": summary, "receipt": str(receipt)}, indent=2, sort_keys=True
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

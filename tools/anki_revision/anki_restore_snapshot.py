#!/usr/bin/env python3
"""Restore exact card content and identities from a trusted Anki snapshot.

The command is a dry run unless ``--apply`` is present. Applying requires an
immutable dry-run receipt, an independent exact backup of the current
collection, and the literal confirmation ``RESTORE_ANKI_SNAPSHOT``.

Existing cards keep their complete current scheduling rows. Notes absent from
the trusted source are removed. Notes that were deleted after the source was
captured are restored with their original Anki note/card identities so the
cloud importer can reactivate the same records instead of creating new cards.
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

import anki_apply
import anki_common as ac


APPLY_CONFIRMATION = "RESTORE_ANKI_SNAPSHOT"
ARTIFACT_SCHEMA = "recall.anki-tag-reversal/v1"
RECEIPT_SCHEMA = "recall.anki-snapshot-restore/v1"
REVALIDATE_PREFIX = "content_revalidate::"


class RestoreError(ValueError):
    """Raised when a snapshot restore cannot be proved safe."""


def _read_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RestoreError(f"could not read {path}: {error}") from error


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _regular_file(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise RestoreError(
            f"{label} is missing, empty, symlinked, or not regular: {path}"
        )


def _load_reversals(path: Path | None) -> tuple[dict[str, tuple[str, str]], str | None]:
    if path is None:
        return {}, None
    _regular_file(path, "tag-reversal artifact")
    payload = _read_json(path)
    if not isinstance(payload, dict) or payload.get("schema") != ARTIFACT_SCHEMA:
        raise RestoreError(f"tag-reversal artifact is not {ARTIFACT_SCHEMA}")
    raw = payload.get("reversals")
    if not isinstance(raw, list):
        raise RestoreError("tag-reversal artifact reversals must be a list")
    result: dict[str, tuple[str, str]] = {}
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise RestoreError(f"reversals[{index}] must be an object")
        guid, source, target = item.get("guid"), item.get("from"), item.get("to")
        values = (guid, source, target)
        if not all(isinstance(value, str) and value for value in values):
            raise RestoreError(f"reversals[{index}] requires guid, from, and to")
        if any(any(char.isspace() for char in value) for value in values):
            raise RestoreError(f"reversals[{index}] values may not contain whitespace")
        if guid in result:
            raise RestoreError(f"duplicate tag reversal guid {guid}")
        result[guid] = (source, target)
    return result, _file_sha256(path)


def _note_rows(connection: sqlite3.Connection) -> dict[int, dict[str, object]]:
    columns = [row[1] for row in connection.execute("PRAGMA table_info(notes)")]
    return {
        int(row[0]): dict(zip(columns, row))
        for row in connection.execute("SELECT * FROM notes ORDER BY id")
    }


def _card_rows(connection: sqlite3.Connection) -> dict[int, list[tuple[object, ...]]]:
    result: dict[int, list[tuple[object, ...]]] = {}
    for row in connection.execute("SELECT * FROM cards ORDER BY nid,id"):
        result.setdefault(int(row[1]), []).append(tuple(row))
    return result


def _table_digest(connection: sqlite3.Connection, table: str) -> str | None:
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    if not exists:
        return None
    columns = [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]
    order = ",".join(f'"{column}"' for column in columns)
    digest = hashlib.sha256()
    for row in connection.execute(f'SELECT * FROM "{table}" ORDER BY {order}'):
        digest.update(repr(tuple(row)).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def _id_map_by_name(connection: sqlite3.Connection, table: str) -> dict[str, int]:
    return {
        str(name): int(identifier)
        for identifier, name in connection.execute(f"SELECT id,name FROM {table}")
    }


def _source_id_to_current_id(
    source: sqlite3.Connection, current: sqlite3.Connection, table: str
) -> dict[int, int]:
    current_by_name = _id_map_by_name(current, table)
    result: dict[int, int] = {}
    for identifier, name in source.execute(f"SELECT id,name FROM {table}"):
        if str(name) not in current_by_name:
            raise RestoreError(
                f"source {table} name is absent from current collection: {name}"
            )
        result[int(identifier)] = current_by_name[str(name)]
    return result


def _replace_markers(tags: str, pass_tag: str, marker: str) -> str:
    tokens = [
        token for token in tags.split() if not token.startswith(REVALIDATE_PREFIX)
    ]
    tokens.extend((pass_tag, marker))
    return " " + " ".join(dict.fromkeys(tokens)) + " "


def _node_tags(tags: str) -> set[str]:
    return {token for token in tags.split() if token.startswith("node::")}


def _restore_node_tags(current_tags: str, source_tags: str) -> str:
    """Restore source ownership without removing unrelated current audit tags."""
    tokens = [token for token in current_tags.split() if not token.startswith("node::")]
    tokens.extend(token for token in source_tags.split() if token.startswith("node::"))
    return " " + " ".join(dict.fromkeys(tokens)) + " "


def _restore_tags(
    original: str,
    guid: str,
    reversals: dict[str, tuple[str, str]],
    pass_tag: str,
    marker: str,
) -> tuple[str, bool]:
    tokens = original.split()
    reversed_scope = False
    reversal = reversals.get(guid)
    if reversal:
        source, target = reversal
        source_tag, target_tag = f"node::{source}", f"node::{target}"
        if target_tag not in tokens:
            raise RestoreError(
                f"guid {guid}: expected scope tag {target_tag} is absent"
            )
        tokens = [token for token in tokens if token != target_tag]
        if source_tag not in tokens:
            tokens.append(source_tag)
        reversed_scope = True
    return _replace_markers(
        " " + " ".join(tokens) + " ", pass_tag, marker
    ), reversed_scope


def _plan(
    current: sqlite3.Connection,
    source: sqlite3.Connection,
    reversals: dict[str, tuple[str, str]],
) -> dict[str, object]:
    anki_apply.require_collection(current, "current collection")
    anki_apply.require_collection(source, "source snapshot")
    current_notes, source_notes = _note_rows(current), _note_rows(source)
    current_cards, source_cards = _card_rows(current), _card_rows(source)
    current_ids, source_ids = set(current_notes), set(source_notes)
    common = current_ids & source_ids
    current_only, source_only = current_ids - source_ids, source_ids - current_ids

    for nid in sorted(common):
        if current_notes[nid]["guid"] != source_notes[nid]["guid"]:
            raise RestoreError(f"nid {nid}: current/source GUID identity mismatch")
    current_guid_to_nid = {str(row["guid"]): nid for nid, row in current_notes.items()}
    if len(current_guid_to_nid) != len(current_notes):
        raise RestoreError("current collection contains duplicate note GUIDs")
    source_guid_to_nid = {str(row["guid"]): nid for nid, row in source_notes.items()}
    if len(source_guid_to_nid) != len(source_notes):
        raise RestoreError("source snapshot contains duplicate note GUIDs")
    for guid in set(current_guid_to_nid) & set(source_guid_to_nid):
        if current_guid_to_nid[guid] != source_guid_to_nid[guid]:
            raise RestoreError(f"guid {guid}: current/source NID identity mismatch")

    missing_card_rows = sorted(nid for nid in source_ids if not source_cards.get(nid))
    if missing_card_rows:
        raise RestoreError(f"source notes lack card rows: {missing_card_rows[:5]}")
    unknown_reversals = sorted(set(reversals) - set(source_guid_to_nid))
    if unknown_reversals:
        raise RestoreError(
            f"tag reversals name GUIDs absent from source: {unknown_reversals[:5]}"
        )

    content_changed = {
        nid
        for nid in common
        if any(
            current_notes[nid][field] != source_notes[nid][field]
            for field in ("flds", "sfld", "csum")
        )
    }
    source_card_ids = {int(card[0]) for rows in source_cards.values() for card in rows}
    current_card_ids = {
        int(card[0]) for rows in current_cards.values() for card in rows
    }
    conflicts = sorted(
        source_card_ids
        & current_card_ids
        - {int(card[0]) for nid in common for card in current_cards.get(nid, [])}
    )
    if conflicts:
        raise RestoreError(
            f"source-only card IDs collide with current cards: {conflicts[:5]}"
        )

    identities = [
        (
            nid,
            str((source_notes.get(nid) or current_notes[nid])["guid"]),
        )
        for nid in sorted(current_ids | source_ids)
    ]
    identity_digest = hashlib.sha256(
        json.dumps(identities, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        "common_notes": len(common),
        "content_edits": len(content_changed),
        "node_mapping_restores": sum(
            _node_tags(str(current_notes[nid]["tags"]))
            != _node_tags(str(source_notes[nid]["tags"]))
            for nid in common
        ),
        "delete_notes": len(current_only),
        "restore_notes": len(source_only),
        "scope_reversals": len(reversals),
        "current_note_count": len(current_ids),
        "expected_note_count": len(source_ids),
        "expected_card_count": sum(len(rows) for rows in source_cards.values()),
        "common_nids": sorted(common),
        "delete_nids": sorted(current_only),
        "restore_nids": sorted(source_only),
        "identity_digest": identity_digest,
    }


def _receipt_path(receipts_dir: Path, kind: str, digest: str) -> Path:
    receipts_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipts_dir.chmod(0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    return receipts_dir / f"{kind}-{digest[:12]}-{stamp}.json"


def _write_receipt(receipts_dir: Path, kind: str, payload: dict[str, object]) -> Path:
    path = _receipt_path(receipts_dir, kind, str(payload["restore_digest"]))
    encoded = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(encoded)
    return path


def _load_dry_receipt(path: Path) -> dict[str, object]:
    _regular_file(path, "dry-run receipt")
    payload = _read_json(path)
    if (
        not isinstance(payload, dict)
        or payload.get("schema") != RECEIPT_SCHEMA
        or payload.get("kind") != "dry_run"
    ):
        raise RestoreError(
            "--dry-run-receipt is not a snapshot-restore dry-run receipt"
        )
    return payload


def _verify_backup(
    current: sqlite3.Connection, db_path: Path, backup_path: Path
) -> None:
    _regular_file(backup_path, "backup")
    try:
        if os.path.samefile(db_path, backup_path):
            raise RestoreError("backup must be independent from the current database")
    except OSError as error:
        raise RestoreError(f"could not compare backup and database: {error}") from error
    backup = ac.connect(str(backup_path), ro=True)
    try:
        anki_apply.require_collection(backup, "backup")
        if anki_apply.collection_digest(backup) != anki_apply.collection_digest(
            current
        ):
            raise RestoreError(
                "backup is not an exact logical copy of the current collection"
            )
    finally:
        backup.close()


def _restore_digest(
    source_sha: str,
    source_collection_digest: str,
    current_digest: str,
    plan: dict[str, object],
    tag_artifact_sha: str | None,
    pass_tag: str,
    marker: str,
) -> str:
    payload = {
        "source_sha256": source_sha,
        "source_collection_digest": source_collection_digest,
        "current_collection_digest": current_digest,
        "plan": plan,
        "tag_reversal_sha256": tag_artifact_sha,
        "pass_tag": pass_tag,
        "marker": marker,
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def execute_restore(
    *,
    db_path: Path,
    source_path: Path,
    receipts_dir: Path,
    pass_tag: str,
    marker: str,
    commit: bool,
    backup_path: Path | None = None,
    dry_run_receipt: Path | None = None,
    tag_reversal_path: Path | None = None,
) -> tuple[dict[str, object], Path]:
    _regular_file(db_path, "current database")
    _regular_file(source_path, "source snapshot")
    if os.path.samefile(db_path, source_path):
        raise RestoreError(
            "source snapshot must be independent from the current database"
        )
    if not pass_tag or any(char.isspace() for char in pass_tag):
        raise RestoreError("pass tag must be one non-empty Anki tag")
    if not marker.startswith(REVALIDATE_PREFIX) or any(
        char.isspace() for char in marker
    ):
        raise RestoreError(f"marker must be one {REVALIDATE_PREFIX} tag")
    reversals, tag_artifact_sha = _load_reversals(tag_reversal_path)
    source_sha = _file_sha256(source_path)
    current = ac.connect(str(db_path), ro=not commit)
    source = ac.connect(str(source_path), ro=True)
    try:
        if commit:
            current.execute("BEGIN IMMEDIATE")
        plan = _plan(current, source, reversals)
        current_digest = anki_apply.collection_digest(current)
        source_digest = anki_apply.collection_digest(source)
        review_history_digest = _table_digest(current, "revlog")
        restore_digest = _restore_digest(
            source_sha,
            source_digest,
            current_digest,
            plan,
            tag_artifact_sha,
            pass_tag,
            marker,
        )
        base: dict[str, object] = {
            "schema": RECEIPT_SCHEMA,
            "kind": "apply" if commit else "dry_run",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "restore_digest": restore_digest,
            "source_sha256": source_sha,
            "source_collection_digest": source_digest,
            "collection_digest_before": current_digest,
            "review_history_digest": review_history_digest,
            "tag_reversal_sha256": tag_artifact_sha,
            "pass_tag": pass_tag,
            "marker": marker,
            "plan": {
                key: value
                for key, value in plan.items()
                if not key.endswith("_nids") and key != "common_nids"
            },
        }
        if not commit:
            path = _write_receipt(receipts_dir, "dry-run", base)
            return base, path

        if backup_path is None:
            raise RestoreError("--backup is required when applying")
        if dry_run_receipt is None:
            raise RestoreError("--dry-run-receipt is required when applying")
        receipt = _load_dry_receipt(dry_run_receipt)
        for key, expected in (
            ("restore_digest", restore_digest),
            ("source_sha256", source_sha),
            ("collection_digest_before", current_digest),
            ("review_history_digest", review_history_digest),
            ("tag_reversal_sha256", tag_artifact_sha),
            ("pass_tag", pass_tag),
            ("marker", marker),
        ):
            if receipt.get(key) != expected:
                raise RestoreError(
                    f"dry-run receipt {key} does not match current apply"
                )
        _verify_backup(current, db_path, backup_path)

        current_notes, source_notes = _note_rows(current), _note_rows(source)
        current_cards, source_cards = _card_rows(current), _card_rows(source)
        deck_map = _source_id_to_current_id(source, current, "decks")
        notetype_map = _source_id_to_current_id(source, current, "notetypes")
        now_s = int(time.time())
        original_common_cards = {nid: current_cards[nid] for nid in plan["common_nids"]}

        for nid in plan["delete_nids"]:
            for card in current_cards.get(nid, []):
                current.execute(
                    "INSERT OR REPLACE INTO graves (oid,type,usn) VALUES (?,0,-1)",
                    (int(card[0]),),
                )
            current.execute(
                "INSERT OR REPLACE INTO graves (oid,type,usn) VALUES (?,1,-1)",
                (nid,),
            )
            current.execute("DELETE FROM cards WHERE nid=?", (nid,))
            current.execute("DELETE FROM notes WHERE id=?", (nid,))

        scope_reversed = 0
        for nid in plan["common_nids"]:
            source_note = source_notes[nid]
            current_note = current_notes[nid]
            tags, did_reverse = _restore_tags(
                _restore_node_tags(str(current_note["tags"]), str(source_note["tags"])),
                str(current_note["guid"]),
                reversals,
                pass_tag,
                marker,
            )
            scope_reversed += int(did_reverse)
            current.execute(
                "UPDATE notes SET flds=?,sfld=?,csum=?,tags=?,mod=?,usn=-1 WHERE id=?",
                (
                    source_note["flds"],
                    source_note["sfld"],
                    source_note["csum"],
                    tags,
                    now_s,
                    nid,
                ),
            )

        note_columns = [row[1] for row in source.execute("PRAGMA table_info(notes)")]
        card_columns = [row[1] for row in source.execute("PRAGMA table_info(cards)")]
        note_insert = f"INSERT INTO notes ({','.join(note_columns)}) VALUES ({','.join('?' for _ in note_columns)})"
        card_insert = f"INSERT INTO cards ({','.join(card_columns)}) VALUES ({','.join('?' for _ in card_columns)})"
        for nid in plan["restore_nids"]:
            source_note = dict(source_notes[nid])
            source_note["mid"] = notetype_map[int(source_note["mid"])]
            source_note["mod"] = now_s
            source_note["usn"] = -1
            restored_tags, did_reverse = _restore_tags(
                str(source_note["tags"]),
                str(source_note["guid"]),
                reversals,
                pass_tag,
                marker,
            )
            scope_reversed += int(did_reverse)
            source_note["tags"] = restored_tags
            current.execute(
                note_insert, tuple(source_note[column] for column in note_columns)
            )
            current.execute("DELETE FROM graves WHERE oid=? AND type=1", (nid,))
            for card in source_cards[nid]:
                values = list(card)
                values[2] = deck_map[int(values[2])]
                values[4] = now_s
                values[5] = -1
                current.execute(card_insert, tuple(values))
                current.execute(
                    "DELETE FROM graves WHERE oid=? AND type=0", (int(values[0]),)
                )

        if scope_reversed != len(reversals):
            raise RestoreError(
                f"applied {scope_reversed} scope reversals, expected {len(reversals)}"
            )
        for tag in (pass_tag, marker):
            current.execute(
                "INSERT OR IGNORE INTO tags (tag,usn,collapsed,config) VALUES (?,-1,0,NULL)",
                (tag,),
            )
        current.execute("UPDATE col SET mod=?", (int(time.time() * 1000),))

        post_notes, post_cards = _note_rows(current), _card_rows(current)
        if len(post_notes) != int(plan["expected_note_count"]):
            raise RestoreError("post-restore note count does not match source")
        if sum(len(rows) for rows in post_cards.values()) != int(
            plan["expected_card_count"]
        ):
            raise RestoreError("post-restore card count does not match source")
        for nid, source_note in source_notes.items():
            post = post_notes[nid]
            for field in ("guid", "flds", "sfld", "csum"):
                if post[field] != source_note[field]:
                    raise RestoreError(
                        f"nid {nid}: restored {field} does not match source"
                    )
            expected_tags, _ = _restore_tags(
                str(source_note["tags"]),
                str(source_note["guid"]),
                reversals,
                pass_tag,
                marker,
            )
            if _node_tags(str(post["tags"])) != _node_tags(expected_tags):
                raise RestoreError(
                    f"nid {nid}: restored concept ownership differs from source"
                )
        for nid, rows in original_common_cards.items():
            if post_cards[nid] != rows:
                raise RestoreError(f"nid {nid}: current scheduling/card rows changed")
        integrity = current.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RestoreError(f"post-restore integrity check failed: {integrity}")
        if _table_digest(current, "revlog") != review_history_digest:
            raise RestoreError("review history changed during content restore")
        current.commit()

        readback = ac.connect(str(db_path), ro=True)
        try:
            after_digest = anki_apply.collection_digest(readback)
        finally:
            readback.close()
        base.update(
            {
                "backup": str(backup_path),
                "dry_run_receipt": str(dry_run_receipt),
                "collection_digest_after": after_digest,
                "integrity": integrity,
                "scope_reversals_applied": scope_reversed,
            }
        )
        path = _write_receipt(receipts_dir, "apply", base)
        return base, path
    except Exception:
        if commit:
            current.rollback()
        raise
    finally:
        source.close()
        current.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path(ac.LIVE_DB))
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--receipts-dir", type=Path, required=True)
    parser.add_argument("--pass-tag", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--tag-reversals", type=Path)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--dry-run-receipt", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmation")
    args = parser.parse_args()
    if args.apply and args.confirmation != APPLY_CONFIRMATION:
        parser.error(f"--apply requires --confirmation {APPLY_CONFIRMATION}")
    try:
        summary, receipt = execute_restore(
            db_path=args.db,
            source_path=args.source,
            receipts_dir=args.receipts_dir,
            pass_tag=args.pass_tag,
            marker=args.marker,
            commit=args.apply,
            backup_path=args.backup,
            dry_run_receipt=args.dry_run_receipt,
            tag_reversal_path=args.tag_reversals,
        )
    except (RestoreError, anki_apply.ApplyError, sqlite3.Error) as error:
        parser.exit(1, f"Anki snapshot restore rejected: {error}\n")
    print(
        json.dumps(
            {"summary": summary, "receipt": str(receipt)}, indent=2, sort_keys=True
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

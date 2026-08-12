#!/usr/bin/env python3
"""Apply reviewed Anki tag removals with compare-and-swap guards.

The semantic content importer can add tags but intentionally cannot remove them.
This companion is dry-run by default and handles only the separately compiled
``tag_mutations.json`` artifact. It never changes fields, cards, scheduling, or
decks.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any


APPLY_CONFIRMATION = "APPLY_TAG_MUTATIONS"


class MutationError(ValueError):
    """Raised when a tag mutation cannot be applied safely."""


def _tag_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(tag, str) and tag.strip() and not any(c.isspace() for c in tag)
        for tag in value
    ):
        raise MutationError(f"{label} must be a list of tag tokens")
    if len(value) != len(set(value)):
        raise MutationError(f"{label} contains duplicate tags")
    return value


def load_mutations(path: Path) -> list[dict[str, object]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MutationError(f"could not read mutations: {error}") from error
    if not isinstance(payload, list):
        raise MutationError("mutations must be a JSON list")

    seen_nids: set[int] = set()
    mutations: list[dict[str, object]] = []
    for index, raw in enumerate(payload):
        label = f"mutations[{index}]"
        if not isinstance(raw, dict):
            raise MutationError(f"{label} must be an object")
        nid = raw.get("nid")
        if not isinstance(nid, int) or nid <= 0:
            raise MutationError(f"{label}.nid must be a positive integer")
        if nid in seen_nids:
            raise MutationError(f"duplicate nid {nid}")
        seen_nids.add(nid)
        add = _tag_list(raw.get("add"), f"{label}.add")
        remove = _tag_list(raw.get("remove"), f"{label}.remove")
        expected = _tag_list(
            raw.get("expected_original_tags"),
            f"{label}.expected_original_tags",
        )
        if not remove:
            raise MutationError(f"{label}.remove must not be empty")
        overlap = set(add).intersection(remove)
        if overlap:
            raise MutationError(
                f"{label} puts tags in both add and remove: {sorted(overlap)}"
            )
        mutations.append(
            {
                "nid": nid,
                "add": add,
                "remove": remove,
                "expected_original_tags": expected,
            }
        )
    return mutations


def _anki_tags(tokens: list[str]) -> str:
    return f" {' '.join(tokens)} " if tokens else ""


def _unicase(left: str, right: str) -> int:
    """Match the case-insensitive collation referenced by Anki's schema."""
    return (left.lower() > right.lower()) - (left.lower() < right.lower())


def desired_tags(current: str, mutation: dict[str, object]) -> str:
    """Return the exact desired tag string or reject unexpected live state."""
    nid = mutation["nid"]
    tokens = current.split()
    token_set = set(tokens)
    add = set(mutation["add"])
    remove = set(mutation["remove"])
    expected = set(mutation["expected_original_tags"])

    missing_adds = add - token_set
    if missing_adds:
        raise MutationError(
            f"nid {nid}: content importer has not added tags {sorted(missing_adds)}"
        )
    missing_stable = (expected - remove) - token_set
    if missing_stable:
        raise MutationError(
            f"nid {nid}: expected original tags are missing: {sorted(missing_stable)}"
        )

    present_removals = remove.intersection(token_set)
    if present_removals not in (set(), remove):
        raise MutationError(f"nid {nid}: mutation is partially applied")

    allowed_node_tags = {tag for tag in expected.union(add) if tag.startswith("node::")}
    unexpected_nodes = {
        tag for tag in token_set if tag.startswith("node::")
    } - allowed_node_tags
    if unexpected_nodes:
        raise MutationError(
            f"nid {nid}: unexpected node tag(s): {sorted(unexpected_nodes)}"
        )

    if not present_removals:
        return current
    return _anki_tags([tag for tag in tokens if tag not in remove])


REQUIRED_ANKI_TABLES = {
    "cards",
    "col",
    "decks",
    "graves",
    "notes",
    "notetypes",
    "tags",
}


def _require_backup(path: Path | None, db_path: Path) -> None:
    if path is None:
        raise MutationError("--backup is required when applying")
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise MutationError(f"backup is missing, empty, or not a regular file: {path}")
    try:
        if os.path.samefile(path, db_path):
            raise MutationError("backup must be independent from the live database")
    except OSError as error:
        raise MutationError(
            f"could not compare backup and live database: {error}"
        ) from error


def _collection_identity(
    connection: sqlite3.Connection, label: str
) -> tuple[object, ...]:
    tables = {
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    missing = sorted(REQUIRED_ANKI_TABLES - tables)
    if missing:
        raise MutationError(
            f"{label} is not a complete Anki collection; missing {missing}"
        )
    col_rows = connection.execute("SELECT crt, scm FROM col").fetchall()
    if len(col_rows) != 1:
        raise MutationError(f"{label} must contain exactly one collection row")
    decks = connection.execute("SELECT id, name FROM decks ORDER BY id").fetchall()
    notetypes = connection.execute(
        "SELECT id, name FROM notetypes ORDER BY id"
    ).fetchall()
    if not decks or not notetypes:
        raise MutationError(f"{label} has no deck or note-type metadata")
    orphans = connection.execute(
        "SELECT COUNT(*) FROM cards WHERE nid NOT IN (SELECT id FROM notes)"
    ).fetchone()[0]
    noteless = connection.execute(
        "SELECT COUNT(*) FROM notes WHERE id NOT IN (SELECT nid FROM cards)"
    ).fetchone()[0]
    if orphans or noteless:
        raise MutationError(
            f"{label} is structurally incomplete: orphan_cards={orphans}, "
            f"noteless_notes={noteless}"
        )
    return (tuple(col_rows[0]), tuple(decks), tuple(notetypes))


def _verify_backup(
    path: Path,
    mutations: list[dict[str, object]],
    live_connection: sqlite3.Connection,
) -> None:
    """Prove the supplied backup contains the exact reviewed pre-pass tag state."""
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.create_collation("unicase", _unicase)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise MutationError(f"backup SQLite integrity check failed: {integrity}")
        backup_identity = _collection_identity(connection, "backup")
        live_identity = _collection_identity(live_connection, "live database")
        if backup_identity != live_identity:
            raise MutationError("backup belongs to a different Anki collection")
        for mutation in mutations:
            nid = int(mutation["nid"])
            row = connection.execute(
                "SELECT tags FROM notes WHERE id=?", (nid,)
            ).fetchone()
            if row is None:
                raise MutationError(f"nid {nid}: note is missing from backup")
            actual = str(row[0] or "").split()
            expected = list(mutation["expected_original_tags"])
            if actual != expected:
                raise MutationError(
                    f"nid {nid}: backup tags do not match reviewed original"
                )
    finally:
        connection.close()


def apply_mutations(
    *,
    db_path: Path,
    mutations: list[dict[str, object]],
    backup_path: Path | None,
    commit: bool,
) -> dict[str, Any]:
    if not db_path.is_file() or db_path.is_symlink():
        raise MutationError(
            f"Anki database is missing or not a regular file: {db_path}"
        )

    connection = sqlite3.connect(db_path)
    connection.create_collation("unicase", _unicase)
    try:
        if commit:
            _require_backup(backup_path, db_path)
            assert backup_path is not None
            connection.execute("BEGIN IMMEDIATE")
            _verify_backup(backup_path, mutations, connection)
        rows: dict[int, str] = {}
        for mutation in mutations:
            nid = int(mutation["nid"])
            row = connection.execute(
                "SELECT tags FROM notes WHERE id=?", (nid,)
            ).fetchone()
            if row is None:
                raise MutationError(f"nid {nid}: note is missing from the collection")
            rows[nid] = str(row[0] or "")

        desired_by_nid = {
            int(mutation["nid"]): desired_tags(rows[int(mutation["nid"])], mutation)
            for mutation in mutations
        }
        changed = [
            nid for nid, desired in desired_by_nid.items() if desired != rows[nid]
        ]

        if not commit:
            return {
                "mutations": len(mutations),
                "changed": len(changed),
                "already_applied": len(mutations) - len(changed),
                "verified": 0,
                "integrity": "not-run-dry-run",
            }

        now_s = int(time.time())
        for mutation in mutations:
            nid = int(mutation["nid"])
            before = rows[nid]
            desired = desired_by_nid[nid]
            if desired == before:
                continue
            updated = connection.execute(
                "UPDATE notes SET tags=?, mod=?, usn=-1 WHERE id=? AND tags=?",
                (desired, now_s, nid, before),
            )
            if updated.rowcount != 1:
                raise MutationError(f"nid {nid}: compare-and-swap update failed")
            for tag in mutation["add"]:
                connection.execute(
                    "INSERT OR IGNORE INTO tags (tag, usn, collapsed, config) "
                    "VALUES (?,-1,0,NULL)",
                    (tag,),
                )
        connection.execute("UPDATE col SET mod=?", (int(time.time() * 1000),))

        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise MutationError(f"SQLite integrity check failed: {integrity}")
        for nid, expected_tags in desired_by_nid.items():
            actual = connection.execute(
                "SELECT tags FROM notes WHERE id=?", (nid,)
            ).fetchone()
            if actual is None or str(actual[0] or "").split() != expected_tags.split():
                raise MutationError(f"nid {nid}: exact tag readback failed")
        connection.commit()
        return {
            "mutations": len(mutations),
            "changed": len(changed),
            "already_applied": len(mutations) - len(changed),
            "verified": len(mutations),
            "integrity": integrity,
        }
    except Exception:
        if commit:
            connection.rollback()
        raise
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--mutations", type=Path, required=True)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmation")
    args = parser.parse_args()
    if args.apply and args.confirmation != APPLY_CONFIRMATION:
        parser.error(f"--apply requires --confirmation {APPLY_CONFIRMATION}")
    try:
        summary = apply_mutations(
            db_path=args.db,
            mutations=load_mutations(args.mutations),
            backup_path=args.backup,
            commit=args.apply,
        )
    except (MutationError, sqlite3.Error) as error:
        parser.exit(1, f"tag mutation rejected: {error}\n")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

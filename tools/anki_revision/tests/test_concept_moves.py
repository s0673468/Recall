from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# Importing fixture helpers adds the Anki tool directory to sys.path.
from test_anki_revision import create_collection, write_job

# isort: split
import anki_apply
import anki_lint
import anki_validate
import verify_compiled


class FrozenDatetime(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 11, 13, 12, tzinfo=dt.UTC)


def move_record() -> dict:
    return {
        "nid": 7,
        "action": "edit",
        "revision_kind": "wording",
        "cards": [
            {
                "front": "Old?",
                "back": "Old.",
                "tags_remove": ["node::test"],
                "tags_add": ["node::new", "added"],
            }
        ],
    }


def collection_rows(db: Path) -> list[str]:
    with contextlib.closing(sqlite3.connect(db)) as connection:
        return list(connection.iterdump())


class ConceptMoveTest(unittest.TestCase):
    def test_move_preserves_other_tags_fields_identity_schedule_and_reviews(self):
        for kind in ("wording", "material"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                db, backup = root / "collection.anki2", root / "backup.anki2"
                create_collection(db)
                record = move_record()
                record["revision_kind"] = kind
                original_tags = (
                    " ml node::test keep::first "
                    "content_revalidate::20260101T000000Z keep::last "
                )
                if kind == "material":
                    original_tags += "node::also-old "
                    record["cards"][0]["tags_remove"].append("node::also-old")
                with contextlib.closing(sqlite3.connect(db)) as connection:
                    connection.execute(
                        "UPDATE notes SET tags=? WHERE id=7",
                        (original_tags,),
                    )
                    connection.execute(
                        "CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER, "
                        "usn INTEGER, ease INTEGER, ivl INTEGER, lastIvl INTEGER, "
                        "factor INTEGER, time INTEGER, type INTEGER)"
                    )
                    connection.execute(
                        "INSERT INTO revlog VALUES (1,70,0,3,20,10,2500,900,1)"
                    )
                    connection.commit()
                    before_cards = connection.execute("SELECT * FROM cards").fetchall()
                    before_reviews = connection.execute(
                        "SELECT * FROM revlog"
                    ).fetchall()
                    before_identity = connection.execute(
                        "SELECT id,guid,mid,flds,flags,data FROM notes"
                    ).fetchall()
                shutil.copy2(db, backup)
                job = write_job(root, record, revision_at="20261113T120000Z")
                before_dry = collection_rows(db)
                dry, dry_path = anki_apply.execute_job(
                    job_dir=job, db_path=db, tag="pass::test", commit=False
                )
                self.assertEqual(before_dry, collection_rows(db))
                applied, apply_path = anki_apply.execute_job(
                    job_dir=job,
                    db_path=db,
                    tag="pass::test",
                    commit=True,
                    backup_path=backup,
                    dry_run_receipt=dry_path,
                )
                expected_changes = [
                    {
                        "nid": 7,
                        "tags_add": ["node::new", "added"],
                        "tags_remove": record["cards"][0]["tags_remove"],
                    }
                ]
                for receipt, path in ((dry, dry_path), (applied, apply_path)):
                    self.assertEqual(receipt["tag_changes"], expected_changes)
                    self.assertEqual(
                        json.loads(path.read_text())["tag_changes"], expected_changes
                    )
                with contextlib.closing(sqlite3.connect(db)) as connection:
                    self.assertEqual(
                        connection.execute("SELECT * FROM cards").fetchall(),
                        before_cards,
                    )
                    self.assertEqual(
                        connection.execute("SELECT * FROM revlog").fetchall(),
                        before_reviews,
                    )
                    self.assertEqual(
                        connection.execute(
                            "SELECT id,guid,mid,flds,flags,data FROM notes"
                        ).fetchall(),
                        before_identity,
                    )
                    tags, mod, usn = connection.execute(
                        "SELECT tags,mod,usn FROM notes WHERE id=7"
                    ).fetchone()
                expected_tags = ["ml", "keep::first"]
                if kind == "wording":
                    expected_tags.append("content_revalidate::20260101T000000Z")
                expected_tags += ["keep::last", "node::new", "added", "pass::test"]
                if kind == "material":
                    expected_tags.append("content_revalidate::20261113T120000Z")
                self.assertEqual(tags, " " + " ".join(expected_tags) + " ")
                self.assertGreater(mod, 1)
                self.assertEqual(usn, -1)
                self.assertEqual(
                    verify_compiled.verify(
                        db_path=db,
                        job_dir=job,
                        apply_receipt=apply_path,
                        tag="pass::test",
                    )["status"],
                    "PASS",
                )
                # The existing content and structural validators accept a moved card.
                for module in (anki_validate, anki_lint):
                    with (
                        mock.patch.object(
                            sys, "argv", [module.__name__, "--db", str(db)]
                        ),
                        contextlib.redirect_stdout(io.StringIO()),
                        self.assertRaises(SystemExit) as exit_result,
                    ):
                        module.main()
                    self.assertEqual(exit_result.exception.code, 0)
                # Readback must check moves even without the global concept-tag flag.
                for extra, error in (
                    ("node::test", "still has removed concept tags"),
                    ("node::unrelated", "exactly one concept tag"),
                ):
                    with contextlib.closing(sqlite3.connect(db)) as connection:
                        connection.execute(
                            "UPDATE notes SET tags=? WHERE id=7", (tags + extra + " ",)
                        )
                        connection.commit()
                    with self.assertRaisesRegex(verify_compiled.VerifyError, error):
                        verify_compiled.verify(
                            db_path=db,
                            job_dir=job,
                            apply_receipt=apply_path,
                            tag="pass::test",
                        )

    def test_missing_old_tag_refuses_dry_run_and_stale_apply_without_partial_writes(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db, backup = root / "collection.anki2", root / "backup.anki2"
            create_collection(db)
            with contextlib.closing(sqlite3.connect(db)) as connection:
                connection.execute(
                    "INSERT INTO notes SELECT 8,'guid-8',mid,mod,usn,tags,flds,sfld,csum,flags,data FROM notes"
                )
                connection.execute(
                    "INSERT INTO cards SELECT 80,8,did,ord,mod,usn,type,queue,due,ivl,factor,reps,lapses,left,odue,odid,flags,data FROM cards"
                )
                connection.commit()
            job = write_job(root, move_record())
            # Put another edit first: a later stale move must prevent all writes.
            first = {
                "nid": 8,
                "action": "edit",
                "revision_kind": "wording",
                "cards": [{"front": "Clearer?", "back": "Old."}],
            }
            (job / "manifest.json").write_text(
                json.dumps({"mode": "revise", "nids": [8, 7]})
            )
            (job / "verified" / "batch_001.json").write_text(
                json.dumps([first, move_record()])
            )
            _, dry_path = anki_apply.execute_job(
                job_dir=job, db_path=db, tag="pass::test", commit=False
            )
            with contextlib.closing(sqlite3.connect(db)) as connection:
                connection.execute(
                    "UPDATE notes SET tags=' ml node::other ' WHERE id=7"
                )
                connection.commit()
            shutil.copy2(db, backup)
            before = collection_rows(db)
            receipts = sorted((job / "receipts").iterdir())
            for commit in (False, True):
                with (
                    self.subTest(commit=commit),
                    self.assertRaisesRegex(
                        anki_apply.ApplyError,
                        "nid 7: tags_remove tags are missing.*node::test",
                    ),
                ):
                    anki_apply.execute_job(
                        job_dir=job,
                        db_path=db,
                        tag="pass::test",
                        commit=commit,
                        backup_path=backup,
                        dry_run_receipt=dry_path,
                    )
                self.assertEqual(collection_rows(db), before)
                self.assertEqual(sorted((job / "receipts").iterdir()), receipts)

    def test_removals_require_node_tag_list_and_one_different_node_addition(self):
        cases = [
            (None, ["node::new"], "list of node:: tags"),
            ("node::test", ["node::new"], "list of node:: tags"),
            ([1], ["node::new"], "list of node:: tags"),
            (["ml"], ["node::new"], "list of node:: tags"),
            (["node::test", "ml"], ["node::new"], "list of node:: tags"),
            (["node::bad tag"], ["node::new"], "list of node:: tags"),
            (["node::test"], [], "exactly one different node:: tag"),
            (["node::test"], ["other"], "exactly one different node:: tag"),
            (
                ["node::test"],
                ["node::a", "node::b"],
                "exactly one different node:: tag",
            ),
            (["node::test"], ["node::test"], "exactly one different node:: tag"),
            (
                ["node::old", "node::test"],
                ["node::test"],
                "exactly one different node:: tag",
            ),
        ]
        for removals, additions, error in cases:
            with self.subTest(removals=removals, additions=additions):
                record = move_record()
                record["cards"][0].update(tags_remove=removals, tags_add=additions)
                with self.assertRaisesRegex(anki_apply.ApplyError, error):
                    anki_apply.validate_records({"nids": [7]}, [record])

    def test_removals_are_only_allowed_on_the_single_edit_card(self):
        for action in ("keep", "add", "split", "delete"):
            with self.subTest(action=action):
                record = move_record()
                record["action"] = action
                if action == "split":
                    record["cards"].append({"front": "Child?", "back": "Child."})
                elif action == "delete":
                    record["cards"] = []
                    record["tags_remove"] = ["node::test"]
                with self.assertRaisesRegex(
                    anki_apply.ApplyError, "only valid on an edit card"
                ):
                    anki_apply.validate_records({"nids": [7]}, [record])
        record = move_record()
        record["action"] = "split"
        card = record["cards"][0]
        record["cards"] = [{"front": "Parent?", "back": "Parent."}, card]
        with self.assertRaisesRegex(
            anki_apply.ApplyError, "only valid on an edit card"
        ):
            anki_apply.validate_records({"nids": [7]}, [record])
        record = move_record()
        record["tags_remove"] = record["cards"][0].pop("tags_remove")
        with self.assertRaisesRegex(
            anki_apply.ApplyError, "only valid on an edit card"
        ):
            anki_apply.validate_records({"nids": [7]}, [record])

    def test_legacy_job_receipts_match_pre_move_writer_bytes(self):
        # These fixtures were captured from origin/main before adding move support.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db, backup = root / "collection.anki2", root / "backup.anki2"
            create_collection(db)
            shutil.copy2(db, backup)
            job = write_job(
                root,
                {
                    "nid": 7,
                    "action": "edit",
                    "revision_kind": "wording",
                    "cards": [
                        {"front": "Clearer?", "back": "Old.", "tags_add": ["clarified"]}
                    ],
                },
            )
            with (
                mock.patch.object(anki_apply.dt, "datetime", FrozenDatetime),
                mock.patch.object(anki_apply.time, "time", return_value=1794571200),
            ):
                _, dry_path = anki_apply.execute_job(
                    job_dir=job, db_path=db, tag="pass::test", commit=False
                )
                _, apply_path = anki_apply.execute_job(
                    job_dir=job,
                    db_path=db,
                    tag="pass::test",
                    commit=True,
                    backup_path=backup,
                    dry_run_receipt=dry_path,
                )
            for kind, path in (("dry_run", dry_path), ("apply", apply_path)):
                expected = (
                    Path(__file__).parent / "fixtures" / f"legacy_{kind}_receipt.json"
                ).read_bytes()
                expected = expected.replace(
                    b'"__BACKUP__"', json.dumps(str(backup)).encode()
                )
                expected = expected.replace(
                    b'"__DRY_RUN_RECEIPT__"', json.dumps(str(dry_path)).encode()
                )
                self.assertEqual(path.read_bytes(), expected)


if __name__ == "__main__":
    unittest.main()

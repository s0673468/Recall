from __future__ import annotations

import contextlib
import io
import json
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

import anki_apply  # noqa: E402
import anki_garden_score as garden  # noqa: E402
import anki_lint  # noqa: E402
import verify_compiled  # noqa: E402
import bootstrap_revalidation  # noqa: E402
import apply_revalidation_markers  # noqa: E402


SCHEMA = """
CREATE TABLE notes (
 id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, mod INTEGER, usn INTEGER,
 tags TEXT, flds TEXT, sfld TEXT, csum INTEGER, flags INTEGER, data TEXT
);
CREATE TABLE cards (
 id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER, mod INTEGER,
 usn INTEGER, type INTEGER, queue INTEGER, due INTEGER, ivl INTEGER,
 factor INTEGER, reps INTEGER, lapses INTEGER, left INTEGER, odue INTEGER,
 odid INTEGER, flags INTEGER, data TEXT
);
CREATE TABLE col (crt INTEGER, scm INTEGER, mod INTEGER);
CREATE TABLE decks (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE notetypes (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE tags (tag TEXT PRIMARY KEY, usn INTEGER, collapsed INTEGER, config TEXT);
CREATE TABLE graves (oid INTEGER, type INTEGER, usn INTEGER);
"""


def create_collection(path: Path, *, guid: str = "guid-7") -> None:
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    connection.execute("INSERT INTO col VALUES (1700000000,1700000001,1)")
    connection.execute("INSERT INTO decks VALUES (1,'ML')")
    connection.execute("INSERT INTO notetypes VALUES (1,'Basic')")
    connection.execute("INSERT INTO tags VALUES ('ml',-1,0,NULL)")
    connection.execute(
        "INSERT INTO notes VALUES (7,?,1,1,0,' ml node::test ','Old?\x1fOld.',"
        "'Old?',1,0,'')",
        (guid,),
    )
    connection.execute(
        "INSERT INTO cards VALUES (70,7,1,0,1,0,2,2,99,20,2500,12,3,0,0,0,0,'{}')"
    )
    connection.commit()
    connection.close()


def write_job(
    root: Path, record: dict[str, object], *, revision_at: str | None = None
) -> Path:
    job = root / "jobs" / "job"
    (job / "verified").mkdir(parents=True)
    manifest = {"mode": "revise", "nids": [7], "batches": ["batch_001"]}
    if revision_at:
        manifest["revision_at"] = revision_at
    (job / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    (job / "verified" / "batch_001.json").write_text(
        json.dumps([record]), encoding="utf-8"
    )
    return job


class ApplyTest(unittest.TestCase):
    def test_cli_converts_job_dir_to_path_before_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db = root / "collection.anki2"
            create_collection(db)
            write_job(
                root,
                {
                    "nid": 7,
                    "action": "keep",
                    "cards": [
                        {"front": "Old?", "back": "Old.", "tags_add": []}
                    ],
                },
            )
            argv = [
                "anki_apply.py",
                "--job",
                "job",
                "--db",
                str(db),
                "--root",
                str(root),
                "--tag",
                "cli_path_test",
            ]
            with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(
                io.StringIO()
            ):
                self.assertEqual(anki_apply.main(), 0)

    def test_external_handoff_requires_current_evidence_and_real_node_owner(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp:
            job = Path(temp)
            (job / "verified").mkdir()
            records = [
                {
                    "action": "add",
                    "deck": "Portuguese",
                    "cards": [{"front": "Diga algo.", "back": "Algo.", "tags_add": []}],
                }
            ]
            handoff = {
                "schema": "recall.card-handoff/v1",
                "pass_tag": "pt_test",
                "card_count": 1,
                "checks": [
                    {
                        "id": "golden-standard",
                        "required": True,
                        "path": "docs/card-golden-standard.md",
                        "version": "current-at-apply",
                    },
                    {
                        "id": "duplicate-search",
                        "required": True,
                        "scope": "full-catalog",
                    },
                    {"id": "concept-node-ownership", "required": True},
                ],
            }
            (job / "handoff.json").write_text(json.dumps(handoff))
            standard = TOOL_ROOT.parents[1] / "docs" / "card-golden-standard.md"
            import hashlib

            resolution = {
                "schema": "recall.card-handoff-resolution/v1",
                "checks": {
                    "golden-standard": {
                        "status": "passed",
                        "sha256": hashlib.sha256(standard.read_bytes()).hexdigest(),
                    },
                    "duplicate-search": {
                        "status": "passed",
                        "scope": "full-catalog",
                        "catalog_digest": "sha256:test",
                    },
                    "concept-node-ownership": {
                        "status": "passed",
                        "outcome": "assigned-existing",
                    },
                },
            }
            resolution_path = job / "resolution.json"
            resolution_path.write_text(json.dumps(resolution))
            evidence = anki_apply.validate_handoff(
                job, records, "pt_test", resolution_path
            )
            self.assertEqual(evidence["node_outcome"], "assigned-existing")
            resolution["checks"]["concept-node-ownership"]["outcome"] = (
                "documented-not-applicable"
            )
            resolution_path.write_text(json.dumps(resolution))
            with self.assertRaisesRegex(anki_apply.ApplyError, "outcome is invalid"):
                anki_apply.validate_handoff(job, records, "pt_test", resolution_path)

    def test_apply_requires_backup_receipt_and_confirmation_contract(self) -> None:
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
                    "revision_kind": "material",
                    "cards": [{"front": "New?", "back": "New.", "tags_add": []}],
                },
                revision_at="20260812T120000Z",
            )

            _, dry_path = anki_apply.execute_job(
                job_dir=job, db_path=db, tag="pass::test", commit=False
            )
            with self.assertRaisesRegex(anki_apply.ApplyError, "--backup"):
                anki_apply.execute_job(
                    job_dir=job,
                    db_path=db,
                    tag="pass::test",
                    commit=True,
                    dry_run_receipt=dry_path,
                )

            before_card = (
                sqlite3.connect(db)
                .execute("SELECT * FROM cards WHERE nid=7")
                .fetchone()
            )
            summary, apply_path = anki_apply.execute_job(
                job_dir=job,
                db_path=db,
                tag="pass::test",
                commit=True,
                backup_path=backup,
                dry_run_receipt=dry_path,
            )
            connection = sqlite3.connect(db)
            after_card = connection.execute(
                "SELECT * FROM cards WHERE nid=7"
            ).fetchone()
            fields, tags = connection.execute(
                "SELECT flds,tags FROM notes WHERE id=7"
            ).fetchone()
            connection.close()
            self.assertEqual(before_card, after_card)
            self.assertEqual(fields, "New?\x1fNew.")
            self.assertIn("content_revalidate::20260812T120000Z", tags.split())
            self.assertEqual(summary["integrity"], "ok")
            self.assertNotEqual(dry_path, apply_path)
            self.assertEqual(len(list((job / "receipts").glob("*.json"))), 2)
            verified = verify_compiled.verify(
                db_path=db,
                job_dir=job,
                apply_receipt=apply_path,
                tag="pass::test",
                require_concept_tags=True,
            )
            self.assertEqual(verified["status"], "PASS")

    def test_apply_rejects_non_exact_or_wrong_identity_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db, wrong = root / "collection.anki2", root / "wrong.anki2"
            create_collection(db)
            create_collection(wrong, guid="different-guid")
            job = write_job(
                root,
                {
                    "nid": 7,
                    "action": "edit",
                    "revision_kind": "wording",
                    "cards": [{"front": "Clearer?", "back": "Old.", "tags_add": []}],
                },
            )
            _, dry_path = anki_apply.execute_job(
                job_dir=job, db_path=db, tag="pass::test", commit=False
            )
            with self.assertRaisesRegex(anki_apply.ApplyError, "exact logical copy"):
                anki_apply.execute_job(
                    job_dir=job,
                    db_path=db,
                    tag="pass::test",
                    commit=True,
                    backup_path=wrong,
                    dry_run_receipt=dry_path,
                )

    def test_changed_changeset_cannot_reuse_dry_run_receipt(self) -> None:
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
                    "cards": [{"front": "First?", "back": "Old.", "tags_add": []}],
                },
            )
            _, dry_path = anki_apply.execute_job(
                job_dir=job, db_path=db, tag="pass::test", commit=False
            )
            payload = json.loads((job / "verified" / "batch_001.json").read_text())
            payload[0]["cards"][0]["front"] = "Changed after dry run?"
            (job / "verified" / "batch_001.json").write_text(json.dumps(payload))
            with self.assertRaisesRegex(anki_apply.ApplyError, "changeset_digest"):
                anki_apply.execute_job(
                    job_dir=job,
                    db_path=db,
                    tag="pass::test",
                    commit=True,
                    backup_path=backup,
                    dry_run_receipt=dry_path,
                )

    def test_material_requires_canonical_revision_time(self) -> None:
        record = {
            "nid": 7,
            "action": "edit",
            "revision_kind": "material",
            "cards": [{"front": "New?", "back": "New.", "tags_add": []}],
        }
        with self.assertRaisesRegex(anki_apply.ApplyError, "revision_at"):
            anki_apply.validate_records({"mode": "revise", "nids": [7]}, [record])

    def test_keep_must_match_live_content_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db = root / "collection.anki2"
            create_collection(db)
            job = write_job(
                root,
                {
                    "nid": 7,
                    "action": "keep",
                    "cards": [{"front": "Not old?", "back": "Old.", "tags_add": []}],
                },
            )
            with self.assertRaisesRegex(anki_apply.ApplyError, "keep does not match"):
                anki_apply.execute_job(
                    job_dir=job, db_path=db, tag="pass::test", commit=False
                )


class LintTest(unittest.TestCase):
    def test_supported_bracket_math_is_accepted_but_dollars_are_flagged(self) -> None:
        self.assertFalse(anki_lint.lint_field(r"\[x^2\]"))
        self.assertIn(
            "unsupported-dollar-display-math",
            [kind for kind, _ in anki_lint.lint_field("$$x^2$$")],
        )


class BootstrapTest(unittest.TestCase):
    def test_selects_only_low_scored_live_edits_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db = root / "collection.anki2"
            create_collection(db)
            job = write_job(
                root,
                {
                    "nid": 7,
                    "action": "edit",
                    "revision_kind": "material",
                    "score_before": 3,
                    "cards": [{"front": "Old?", "back": "Old.", "tags_add": []}],
                },
                revision_at="20260812T120000Z",
            )
            before = db.read_bytes()
            rows = bootstrap_revalidation.build_manifest(
                db_path=db, job_dir=job, revision_at="20260812T130000Z"
            )
            self.assertEqual([row["nid"] for row in rows], [7])
            self.assertEqual(rows[0]["add"], ["content_revalidate::20260812T130000Z"])
            self.assertEqual(db.read_bytes(), before)

    def test_bootstrap_tag_apply_is_guarded_and_preserves_content_and_cards(
        self,
    ) -> None:
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
                    "revision_kind": "material",
                    "score_before": 3,
                    "cards": [{"front": "Old?", "back": "Old.", "tags_add": []}],
                },
                revision_at="20260812T120000Z",
            )
            rows = bootstrap_revalidation.build_manifest(
                db_path=db, job_dir=job, revision_at="20260812T130000Z"
            )
            artifact = root / "bootstrap.json"
            artifact.write_text(
                json.dumps(
                    {
                        "schema": "recall.revalidation-bootstrap/v1",
                        "revision_at": "20260812T130000Z",
                        "selection": "action-in-edit-split-and-score-before-lte-3",
                        "mutations": rows,
                    }
                )
            )
            connection = sqlite3.connect(db)
            note_before = connection.execute(
                "SELECT guid,mid,flds FROM notes WHERE id=7"
            ).fetchone()
            card_before = connection.execute(
                "SELECT * FROM cards WHERE nid=7"
            ).fetchone()
            connection.close()
            _, dry = apply_revalidation_markers.execute(
                db_path=db, artifact_path=artifact, commit=False
            )
            result, applied = apply_revalidation_markers.execute(
                db_path=db,
                artifact_path=artifact,
                commit=True,
                backup_path=backup,
                dry_run_receipt=dry,
            )
            connection = sqlite3.connect(db)
            note_after = connection.execute(
                "SELECT guid,mid,flds FROM notes WHERE id=7"
            ).fetchone()
            tags = connection.execute("SELECT tags FROM notes WHERE id=7").fetchone()[0]
            card_after = connection.execute(
                "SELECT * FROM cards WHERE nid=7"
            ).fetchone()
            connection.close()
            self.assertEqual(note_after, note_before)
            self.assertEqual(card_after, card_before)
            self.assertIn("content_revalidate::20260812T130000Z", tags.split())
            self.assertEqual(result["changed"], 1)
            self.assertTrue(applied.is_file())


class GardenTest(unittest.TestCase):
    def test_flags_first_and_mature_slow_material_volatile_signals(self) -> None:
        notes = [
            {
                "nid": nid,
                "guid": f"g{nid}",
                "front": "What?",
                "back": "Answer.",
                "reps": 10,
                "lapses": 1 if nid != 2 else 8,
                "ivl": 10,
            }
            for nid in range(1, 42)
        ]
        metrics = {
            "g3": {"reviews": 5, "again": 4, "elapsed_ms": [20000, 21000, 22000]},
            "g4": {"reviews": 4, "again": 4, "elapsed_ms": [20000, 21000]},
        }
        queue = garden.rank_notes(
            notes,
            review_metrics=metrics,
            flags=[{"nid": 1}],
            validation_failures=[{"guid": "g5"}],
            recheck_due=[{"nid": 6}],
            limit=20,
            min_reviews=5,
            slow_ms=15000,
            min_timed_reviews=3,
        )
        self.assertEqual(len(queue), 20)
        self.assertEqual(queue[0]["nid"], 1)
        by_nid = {row["nid"]: row for row in queue}
        self.assertIn("material_change_validation_failed", by_nid[5]["reasons"])
        self.assertIn("volatile_recheck_due", by_nid[6]["reasons"])
        self.assertIn("mature_again_rate", by_nid[3]["reasons"])
        self.assertIn("slow_answer_rate", by_nid[3]["reasons"])
        self.assertNotIn("mature_again_rate", by_nid[4]["reasons"])

    def test_queue_size_is_bounded_to_twenty_through_forty(self) -> None:
        with self.assertRaisesRegex(garden.GardenError, "between 20 and 40"):
            garden.rank_notes([], limit=19)
        with self.assertRaisesRegex(garden.GardenError, "between 20 and 40"):
            garden.rank_notes([], limit=41)


if __name__ == "__main__":
    unittest.main()

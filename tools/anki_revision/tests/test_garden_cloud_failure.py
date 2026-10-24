"""Synthetic CLI regressions for unavailable current like protection."""

import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import anki_garden_score as garden


class GardenCloudFailureTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.out = self.root / "queue.json"
        self.db = self.root / "synthetic.db"
        connection = sqlite3.connect(self.db)
        try:
            connection.executescript(
                "CREATE TABLE notes(id,guid,tags,flds);"
                "CREATE TABLE cards(nid,reps,lapses,ivl);"
            )
            for nid in (1, 2):
                connection.execute(
                    "INSERT INTO notes VALUES (?,?,?,?)",
                    (nid, f"synthetic-{nid}", "", "Synthetic?\x1fAnswer."),
                )
                connection.execute("INSERT INTO cards VALUES (?,10,0,30)", (nid,))
            connection.commit()
        finally:
            connection.close()
        scores = self.root / "scores.json"
        # Scores generated before a new like have no liked_keep_style marker.
        scores.write_text(json.dumps([
            dict(card_id=1001, quality_score=0, forget_score=1, top_reasons=[])
        ]), encoding="utf-8")
        mapping = self.root / "map.json"
        mapping.write_text(json.dumps([dict(card_id=1001, nid=1)]), encoding="utf-8")
        self.args = ["anki_garden_score.py", "--db", str(self.db), "--out", str(self.out)]
        self.model_args = ["--quality-scores", str(scores), "--quality-card-map", str(mapping)]

    @contextlib.contextmanager
    def cloud(self, failure_at=None):
        client = mock.Mock()
        queries = {}
        for table in ("review_log", "note_flags"):
            query = mock.MagicMock()
            for method in ("select", "eq", "neq", "range"):
                getattr(query, method).return_value = query
            if table == failure_at:
                query.execute.side_effect = TimeoutError("synthetic cloud timeout")
            else:
                query.execute.return_value.data = []
            queries[table] = query
        client.table.side_effect = queries.__getitem__
        module = mock.Mock(create_client=mock.Mock(return_value=client))
        # Opaque objects only reach the mocked client, never a real service.
        env = dict(SUPABASE_URL=mock.sentinel.url,
                   SUPABASE_SERVICE_KEY=mock.sentinel.key,
                   SUPABASE_USER_ID=mock.sentinel.user_id)
        with (
            mock.patch.object(garden.ac, "resolve_cloud_env", return_value=None),
            mock.patch.object(garden, "load_cloud_env", return_value=env),
            mock.patch.dict(sys.modules, {"supabase": module}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            yield queries

    def assert_rejected(self, args):
        stderr = io.StringIO()
        with (
            mock.patch.object(sys, "argv", args),
            contextlib.redirect_stderr(stderr),
            self.assertRaises(SystemExit) as raised,
        ):
            garden.main()
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("current like flags unavailable", stderr.getvalue())
        self.assertNotIn("Synthetic?", stderr.getvalue())

    def run_queue(self, extra):
        with mock.patch.object(sys, "argv", self.args + extra):
            self.assertEqual(garden.main(), 0)
        return json.loads(self.out.read_text(encoding="utf-8"))["queue"]

    def test_timeout_rejects_model_queue_without_writing_or_overwriting_output(self):
        for table in ("review_log", "note_flags"):
            for existing_output in (False, True):
                with self.subTest(table=table, existing_output=existing_output):
                    self.out.unlink(missing_ok=True)
                    if existing_output:
                        self.out.write_text("previous synthetic queue", encoding="utf-8")
                    with self.cloud(failure_at=table):
                        self.assert_rejected(self.args + self.model_args)
                    if existing_output:
                        self.assertEqual(self.out.read_text(), "previous synthetic queue")
                    else:
                        self.assertFalse(self.out.exists())

    def test_unavailable_credentials_also_reject_model_queue(self):
        with (
            self.cloud(),
            mock.patch.object(garden, "load_cloud_env", return_value={}),
            mock.patch.dict(garden.os.environ, {}, clear=True),
        ):
            self.assert_rejected(self.args + self.model_args)
        self.assertFalse(self.out.exists())

    def test_timeout_can_use_explicit_flags_including_an_empty_snapshot(self):
        flags = self.root / "flags.json"
        for rows in ([dict(guid="synthetic-1", reason="like", status="open")], []):
            with self.subTest(rows=rows):
                flags.write_text(json.dumps(rows), encoding="utf-8")
                with self.cloud(failure_at="note_flags"):
                    queue = self.run_queue(self.model_args + ["--flags-file", str(flags)])
                self.assertEqual({row["nid"] for row in queue}, {2} if rows else {1, 2})

    def test_successfully_fetched_empty_flags_allow_model_queue(self):
        with self.cloud() as queries:
            queue = self.run_queue(self.model_args)
        self.assertEqual(queue[0]["nid"], 1)
        self.assertEqual(queue[0]["priority"], 0.45)
        queries["note_flags"].neq.assert_not_called()

    def test_explicit_offline_model_run_does_not_fetch_cloud(self):
        with (
            mock.patch.object(garden, "fetch_cloud_signals") as fetch,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            queue = self.run_queue(self.model_args + ["--no-cloud"])
        self.assertEqual(queue[0]["nid"], 1)
        fetch.assert_not_called()

    def test_timeout_preserves_queue_without_model_scores(self):
        with self.cloud(failure_at="review_log"):
            queue = self.run_queue([])
        self.assertEqual([row["nid"] for row in queue], [1, 2])


if __name__ == "__main__":
    unittest.main()

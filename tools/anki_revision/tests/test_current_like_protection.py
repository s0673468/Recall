"""Synthetic cloud-to-gardening regressions; no live data or services."""

import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import anki_garden_score as garden


class CurrentLikeProtectionTest(unittest.TestCase):
    def cloud_client(self):
        flags = [
            dict(guid="synthetic-1", reason="like", status="open"),
            dict(guid="synthetic-2", reason="wrong", status="open"),
        ]
        excluded_reasons = []
        flag_query = mock.MagicMock()
        for method in ("select", "eq"):
            getattr(flag_query, method).return_value = flag_query

        def exclude(column, reason):
            self.assertEqual(column, "reason")
            excluded_reasons.append(reason)
            return flag_query

        flag_query.neq.side_effect = exclude
        flag_query.execute.side_effect = lambda: SimpleNamespace(
            data=[row for row in flags if row["reason"] not in excluded_reasons]
        )
        review_query = mock.MagicMock()
        for method in ("select", "eq", "range"):
            getattr(review_query, method).return_value = review_query
        review_query.execute.return_value.data = []
        client = mock.Mock()
        client.table.side_effect = {
            "note_flags": flag_query, "review_log": review_query
        }.__getitem__
        return client, flag_query

    def cloud_env(self):
        # Opaque sentinels reach only the mocked client, never a real service.
        return dict(
            SUPABASE_URL=mock.sentinel.url,
            SUPABASE_SERVICE_KEY=mock.sentinel.key,
            SUPABASE_USER_ID=mock.sentinel.user_id,
        )

    def test_cloud_can_include_current_likes_without_losing_corrective_flags(self):
        client, query = self.cloud_client()
        module = mock.Mock(create_client=mock.Mock(return_value=client))
        with mock.patch.dict(sys.modules, {"supabase": module}):
            reviews, flags, summary = garden.fetch_cloud_signals(
                self.cloud_env(), include_likes=True
            )
        self.assertEqual(reviews, [])
        self.assertEqual([row["reason"] for row in flags], ["like", "wrong"])
        self.assertEqual(summary, "reviews=0 open_flags=2")
        query.select.assert_called_once_with("guid,reason,status")
        query.eq.assert_any_call("user_id", mock.sentinel.user_id)
        query.eq.assert_any_call("status", "open")
        query.neq.assert_not_called()

    def test_cli_protects_likes_added_after_scoring_and_preserves_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db, scores, mapping, out = [
                root / name for name in ("synthetic.db", "scores.json", "map.json", "queue.json")
            ]
            connection = sqlite3.connect(db)
            try:
                connection.executescript(
                    "CREATE TABLE notes(id,guid,tags,flds);"
                    "CREATE TABLE cards(nid,reps,lapses,ivl);"
                )
                for nid in range(1, 4):
                    connection.execute(
                        "INSERT INTO notes VALUES (?,?,?,?)",
                        (nid, f"synthetic-{nid}", "", "Synthetic question?\x1fSynthetic answer."),
                    )
                    connection.execute("INSERT INTO cards VALUES (?,10,0,30)", (nid,))
                connection.commit()
            finally:
                connection.close()
            mapping.write_text(json.dumps([dict(card_id=1001, nid=1)]), encoding="utf-8")
            for quality, forget in ((0, 0), (1, 1), (0, 1)):
                # Persisted before the like: no liked_keep_style marker.
                scores.write_text(json.dumps([
                    dict(card_id=1001, quality_score=quality, forget_score=forget, top_reasons=[])
                ]), encoding="utf-8")
                for use_scores in (False, True):
                    with self.subTest(quality=quality, forget=forget, use_scores=use_scores):
                        client, query = self.cloud_client()
                        module = mock.Mock(create_client=mock.Mock(return_value=client))
                        args = ["anki_garden_score.py", "--db", str(db), "--out", str(out)]
                        if use_scores:
                            args += ["--quality-scores", str(scores), "--quality-card-map", str(mapping)]
                        output = io.StringIO()
                        with (
                            mock.patch.object(sys, "argv", args),
                            mock.patch.object(garden.ac, "resolve_cloud_env", return_value=None),
                            mock.patch.object(garden, "load_cloud_env", return_value=self.cloud_env()),
                            mock.patch.dict(sys.modules, {"supabase": module}),
                            contextlib.redirect_stdout(output),
                        ):
                            self.assertEqual(garden.main(), 0)
                        payload = json.loads(out.read_text(encoding="utf-8"))
                        queue = payload["queue"]
                        self.assertEqual(queue[0]["nid"], 2)
                        self.assertEqual(queue[0]["lane"], "flagged")
                        self.assertIn(3, [row["nid"] for row in queue])
                        if use_scores:
                            self.assertNotIn(1, [row["nid"] for row in queue])
                            query.neq.assert_not_called()
                        else:
                            self.assertEqual([row["nid"] for row in queue], [2, 1, 3])
                            query.neq.assert_called_once_with("reason", "like")
                        self.assertNotIn("Synthetic question", out.read_text() + output.getvalue())
                        self.assertNotIn("Synthetic answer", out.read_text() + output.getvalue())


if __name__ == "__main__":
    unittest.main()

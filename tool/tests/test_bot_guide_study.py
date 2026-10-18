"""Exercise the guide's queries on synthetic, in-memory data; no services.

SQLite executes joins, filters, aggregates and windows. The adapter below only
maps PostgreSQL date/time and tag-splitting syntax to Python/SQLite equivalents;
this does not claim PostgreSQL parsing, deployed RLS, or live connector coverage.
"""
from datetime import date, datetime
import json
from pathlib import Path
import re
import sqlite3
import unittest
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "docs/bot-guide-study.md"


def local_time(zone, instant):
    return datetime.fromisoformat(instant.replace("Z", "+00:00")).astimezone(ZoneInfo(zone))


class BotGuideStudyTest(unittest.TestCase):
    def setUp(self):
        self.guide = GUIDE.read_text()
        self.queries = re.findall(r"```sql\n(.*?)\n```", self.guide, re.S)
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.db.create_function("owner", 0, lambda: "learner")
        self.db.create_function("local_day", 2, lambda z, t: local_time(z, t).date().isoformat())
        self.db.create_function("local_hour", 2, lambda z, t: local_time(z, t).hour)
        self.db.create_function("date_gap", 2, lambda a, b: (date.fromisoformat(a)-date.fromisoformat(b)).days)
        self.db.create_function("split_tags", 1, lambda tags: json.dumps(tags.split()))
        self.db.executescript("""
          CREATE TABLE decks (deck_id INTEGER, user_id TEXT, name TEXT, deleted BOOLEAN);
          CREATE TABLE notes (id INTEGER, user_id TEXT, deck_id INTEGER, tags TEXT, deleted BOOLEAN);
          CREATE TABLE cards (id INTEGER, user_id TEXT, note_id INTEGER, state INTEGER,
            due TEXT, stability REAL, reps INTEGER, lapses INTEGER, suspended BOOLEAN, deleted BOOLEAN);
          CREATE TABLE note_flags (user_id TEXT, card_id INTEGER, reason TEXT, status TEXT);
          CREATE TABLE review_log (user_id TEXT, card_id INTEGER, rating_at TEXT,
            rating INTEGER, client_event_id TEXT);
          CREATE TABLE concept_nodes (node_id TEXT, title TEXT, module TEXT);
          CREATE TABLE concept_pages (node_id TEXT, body_html TEXT, figure_svg TEXT, updated_at TEXT);
        """)
        self.db.executemany("INSERT INTO decks VALUES (?,?,?,?)", [
            (100, "learner", "Synthetic", False), (200, "learner", "Opt-in::Synthetic", False),
            (300, "learner", "Removed", True), (100, "other", "Other", False),
        ])
        for card_id in range(1, 15):
            owner = "other" if card_id == 13 else "learner"
            deck = 300 if card_id == 8 else 200 if card_id == 12 else 100
            note_owner = "other" if card_id == 14 else owner
            tags = "node::alpha node::alpha\tnode::beta node::none node::missing" if card_id == 1 else (
                "node::alpha" if card_id in (2, 3) else "node::beta" if card_id == 4 else "")
            self.db.execute("INSERT INTO notes VALUES (?,?,?,?,?)", (card_id, note_owner, deck, tags, card_id == 7))
            state, due, stability, reps, lapses = {
                2: (0, None, 0, 0, 0),
                3: (3, "2026-10-18T19:00:00Z", 1, 5, 3),
                4: (1, "2026-10-17T10:00:00Z", .5, 1, 0),
                11: (2, None, 10, 3, 0),
                12: (2, "2026-10-19T10:00:00Z", 5, 4, 1),
            }.get(card_id, (2, "2026-10-18T10:00:00Z", 2, 5, 2))
            self.db.execute("INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?)", (
                card_id, owner, card_id, state, due, stability, reps, lapses, card_id == 5, card_id == 6))
        self.db.executemany("INSERT INTO note_flags VALUES (?,?,?,?)", [
            ("learner", 9, "dislike", "open"), ("learner", 10, "delete", "open"),
            ("learner", 11, "dislike", "resolved"), ("learner", 1, "confusing", "open"),
            ("other", 1, "delete", "open"),
        ])
        self.db.executemany("INSERT INTO review_log VALUES (?,?,?,?,?)", [
            ("learner", 1, "2026-10-16T23:00:00Z", 1, None),
            ("learner", 1, "2026-10-17T04:00:00Z", 2, "event-a"),
            ("learner", 1, "2026-10-18T03:59:00Z", 3, "event-b"),
            ("learner", 3, "2026-10-18T04:00:00Z", 4, None),
            ("learner", 3, "2026-10-18T15:00:00Z", 1, None),
            ("learner", 3, "2026-10-18T15:00:00Z", 2, None),
            ("other", 13, "2026-10-18T15:00:00Z", 1, None),
            ("learner", 1, "2026-10-18T17:00:00Z", 1, "future"),
        ])
        self.db.executemany("INSERT INTO concept_nodes VALUES (?,?,?)", [
            (node, node, "Synthetic") for node in ("alpha", "beta", "none")])
        self.db.execute("INSERT INTO concept_pages VALUES ('alpha', '', NULL, '2026-10-18T04:00:00Z')")
        self.params = dict(tz="America/New_York", as_of="2026-10-18T16:00:00Z",
                           today="2026-10-18", yesterday="2026-10-17",
                           day_end="2026-10-19T04:00:00Z", window_start="2026-10-17T04:00:00Z",
                           window_end="2026-10-18T16:00:00Z", min_cards=1, node_id="alpha")

    def query(self, number, **params):
        sql = self.queries[number-1].replace("public.", "").replace("auth.uid()", "owner()")
        sql = sql.replace("CAST(timezone(:tz, rating_at) AS date)", "local_day(:tz, rating_at)")
        sql = sql.replace("extract(hour FROM timezone(:tz, rating_at))", "local_hour(:tz, rating_at)")
        sql = re.sub(r"CAST\(:(today|yesterday) AS date\)", r":\1", sql)
        sql = sql.replace("a.day-r.day", "date_gap(a.day,r.day)")
        sql = sql.replace("regexp_split_to_table(n.tags, '\\s+') AS tags(value)", "json_each(split_tags(n.tags))")
        allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION, sqlite3.SQLITE_RECURSIVE}
        self.db.set_authorizer(lambda action, *_: sqlite3.SQLITE_OK if action in allowed else sqlite3.SQLITE_DENY)
        try:
            return self.db.execute(sql, self.params | params).fetchall()
        finally:
            self.db.set_authorizer(None)

    def test_document_contract_and_local_links(self):
        self.assertTrue(150 <= len(self.guide.splitlines()) <= 300)
        self.assertEqual(len(self.queries), 10)
        for query in self.queries:
            self.assertRegex(query, r"^(SELECT|WITH)\b")
            self.assertNotRegex(query.lower(), r"\b(insert|update|delete|call|create|drop|alter)\s+(into|from|table|public\.)")
        for link in re.findall(r"\]\(([^)]+)\)", self.guide):
            self.assertTrue((GUIDE.parent / link).is_file(), link)
        self.assertIn("(docs/bot-guide-study.md)", (ROOT / "README.md").read_text())

    def test_active_inventory_and_due_boundaries(self):
        self.assertEqual(self.query(1), [(100, "Synthetic", 0, 1), (100, "Synthetic", 1, 1),
                                      (100, "Synthetic", 2, 2), (100, "Synthetic", 3, 1),
                                      (200, "Opt-in::Synthetic", 2, 1)])
        self.assertEqual(self.query(2), [(1, 1, 1), (2, 1, 1), (3, 0, 1)])
        self.db.execute("UPDATE cards SET due=? WHERE id=3", (self.params["day_end"],))
        self.assertEqual(self.query(2), [(1, 1, 1), (2, 1, 1)])

    def test_daily_counts_retention_and_hourly_patterns(self):
        self.assertEqual(self.query(3), [("2026-10-17", 2), ("2026-10-18", 3)])
        self.assertEqual(self.query(5), [(5, 4, .8)])
        self.assertEqual(self.query(8), [(0, 2, 1.0), (11, 2, .5), (23, 1, 1.0)])
        self.db.execute("INSERT INTO review_log VALUES ('learner',1,?,1,NULL)", (self.params["window_end"],))
        self.db.execute("INSERT INTO review_log VALUES ('learner',1,'2026-10-18T14:00:00Z',9,NULL)")
        self.assertEqual(self.query(5), [(5, 4, .8)])
        self.assertEqual(self.query(5, window_start=self.params["window_end"]), [(0, 0, None)])

    def test_streak_today_yesterday_gap_and_empty_history(self):
        self.assertEqual(self.query(4), [(3,)])
        self.assertEqual(self.query(4, today="2026-10-19", yesterday="2026-10-18"), [(3,)])
        self.assertEqual(self.query(4, today="2026-10-20", yesterday="2026-10-19"), [(0,)])
        self.db.execute("DELETE FROM review_log WHERE rating_at LIKE '2026-10-17%'")
        self.db.execute("DELETE FROM review_log WHERE rating_at LIKE '2026-10-18T03%'")
        self.assertEqual(self.query(4), [(1,)])
        self.db.execute("DELETE FROM review_log")
        self.assertEqual(self.query(4), [(0,)])

    def test_dst_short_day_and_repeated_hour(self):
        self.db.execute("DELETE FROM review_log")
        self.db.executemany("INSERT INTO review_log VALUES ('learner',1,?,?,NULL)", [
            ("2026-03-08T05:00:00Z", 2), ("2026-03-09T03:59:59Z", 3),
            ("2026-03-09T04:00:00Z", 1),
            ("2026-11-01T05:30:00Z", 1), ("2026-11-01T06:30:00Z", 2),
            ("2026-11-02T04:59:59Z", 3), ("2026-11-02T05:00:00Z", 1),
        ])
        self.assertEqual(self.query(3, window_start="2026-03-08T05:00:00Z",
                                    window_end="2026-03-09T04:00:00Z"), [("2026-03-08", 2)])
        self.assertEqual(self.query(3, window_start="2026-11-01T04:00:00Z",
                                    window_end="2026-11-02T05:00:00Z"), [("2026-11-01", 3)])
        self.assertEqual(self.query(8, window_start="2026-11-01T04:00:00Z",
                                    window_end="2026-11-02T05:00:00Z"), [(1, 2, .5), (23, 1, 1.0)])

    def test_weakness_deduplicates_tags_and_excludes_unstudied_cards(self):
        self.assertEqual(self.query(6), [(100, "Synthetic", 4, 5, 1.25, 3.375),
                                      (200, "Opt-in::Synthetic", 1, 1, 1.0, 5.0)])
        self.assertEqual(self.query(7), [("alpha", "alpha", 2, 5, 2.5, 1.5),
                                      ("beta", "beta", 2, 2, 1.0, 1.25)])
        self.assertEqual(self.query(7, min_cards=3), [])

    def test_feedback_and_selected_read_only_primer(self):
        self.assertEqual(self.query(9), [("confusing", 1, 1), ("delete", 1, 1), ("dislike", 1, 1)])
        self.assertEqual(self.query(10), [("alpha", "alpha", "Synthetic", "", None, "2026-10-18T04:00:00Z")])
        self.assertEqual(self.query(10, node_id="missing"), [])


if __name__ == "__main__":
    unittest.main()

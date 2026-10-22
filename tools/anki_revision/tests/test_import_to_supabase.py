"""Invented-collection tests for the one-way desktop -> Supabase importer.

No network: a small in-memory stand-in models the PostgREST behaviour the
importer relies on, including a server row cap and the fact that an unordered
read returns rows in physical (heap) order, where an updated row moves.
"""

from __future__ import annotations

import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

import import_to_supabase as importer  # noqa: E402


CRT = 1_700_000_000
DAY = 86_400

SCHEMA = """
CREATE TABLE col (crt INTEGER);
CREATE TABLE decks (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE deck_config (id INTEGER PRIMARY KEY, name TEXT, config BLOB);
CREATE TABLE notes (
 id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, mod INTEGER, tags TEXT, flds TEXT
);
CREATE TABLE cards (
 id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, type INTEGER, queue INTEGER,
 due INTEGER, reps INTEGER, lapses INTEGER, odue INTEGER, odid INTEGER, data TEXT
);
CREATE TABLE revlog (
 id INTEGER PRIMARY KEY, cid INTEGER, ease INTEGER, type INTEGER,
 factor INTEGER NOT NULL DEFAULT 0
);
"""


def iso(epoch: float) -> str:
    return importer._safe_iso(epoch)


class Collection:
    """An invented Anki collection: one Basic note per card."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.con = sqlite3.connect(path)
        self.con.executescript(SCHEMA)
        self.con.execute("INSERT INTO col VALUES (?)", (CRT,))
        self.con.execute("INSERT INTO decks VALUES (1, 'Home')")
        self.con.execute("INSERT INTO decks VALUES (2, 'Opt-in::Extra')")
        self.con.execute("INSERT INTO decks VALUES (99, 'Filtered Deck 1')")

    def card(
        self,
        cid: int,
        *,
        ctype: int,
        queue: int,
        due: int,
        did: int = 1,
        odid: int = 0,
        odue: int = 0,
        data: dict | None = None,
    ) -> str:
        guid = f"guid-{cid}"
        self.con.execute(
            "INSERT INTO notes VALUES (?,?,1,1,'',?)",
            (cid, guid, f"Front {cid}?\x1fBack {cid}."),
        )
        self.con.execute(
            "INSERT INTO cards VALUES (?,?,?,?,?,?,3,0,?,?,?)",
            (
                cid,
                cid,
                did,
                ctype,
                queue,
                due,
                odue,
                odid,
                json.dumps(data or {}),
            ),
        )
        return guid

    def revlog(
        self, cid: int, at_epoch: int, *, ease: int, rtype: int, factor: int = 0
    ) -> None:
        self.con.execute(
            "INSERT INTO revlog (id, cid, ease, type, factor) VALUES (?,?,?,?,?)",
            (at_epoch * 1000, cid, ease, rtype, factor),
        )

    def payloads(self):
        self.con.commit()
        with contextlib.closing(importer.connect(str(self.path), ro=True)) as con:
            return importer.build_payloads(con)


class BuildPayloadsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.collection = Collection(Path(self.temp.name) / "collection.anki2")

    def test_interday_learning_due_is_a_day_number(self) -> None:
        c = self.collection
        # Anki stores (re)learning steps of a day or more in the day-learn
        # queue (3) with `due` as a day number, like review cards.
        day_learn = c.card(1, ctype=1, queue=3, due=640)
        day_relearn = c.card(2, ctype=3, queue=3, due=641)
        # Suspending or burying hides the queue; Anki itself tells the two
        # units apart by magnitude when it restores such a card.
        suspended_day_learn = c.card(3, ctype=1, queue=-1, due=642)
        buried_day_relearn = c.card(4, ctype=3, queue=-3, due=643)
        intraday = c.card(5, ctype=1, queue=1, due=CRT + 900 * DAY + 600)
        _, _, seed, _ = c.payloads()

        self.assertEqual(seed[day_learn]["due"], iso(CRT + 640 * DAY))
        self.assertEqual(seed[day_relearn]["due"], iso(CRT + 641 * DAY))
        self.assertEqual(seed[suspended_day_learn]["due"], iso(CRT + 642 * DAY))
        self.assertEqual(seed[buried_day_relearn]["due"], iso(CRT + 643 * DAY))
        self.assertEqual(seed[intraday]["due"], iso(CRT + 900 * DAY + 600))
        self.assertEqual(seed[day_learn]["state"], 1)
        self.assertEqual(seed[day_relearn]["state"], 3)

    def test_filtered_deck_card_keeps_its_home_deck_and_real_due(self) -> None:
        c = self.collection
        # Moving a review card into a filtered deck records its home deck and
        # real due date in odid/odue and replaces `due` with a queue position.
        review = c.card(1, ctype=2, queue=2, due=-100_000, did=99, odid=2, odue=700)
        learning = c.card(
            2, ctype=1, queue=1, due=-99_999, did=99, odid=1, odue=CRT + 800 * DAY
        )
        # A new card in a filtered deck has no due date either way.
        new = c.card(3, ctype=0, queue=0, due=-99_998, did=99, odid=1, odue=12)
        home = c.card(4, ctype=2, queue=2, due=710)
        _, notes, seed, _ = c.payloads()
        deck_of = {n["guid"]: n["deck_id"] for n in notes}

        self.assertEqual(deck_of[review], 2)
        self.assertEqual(deck_of[learning], 1)
        self.assertEqual(deck_of[new], 1)
        self.assertEqual(deck_of[home], 1)
        self.assertEqual(seed[review]["due"], iso(CRT + 700 * DAY))
        self.assertEqual(seed[learning]["due"], iso(CRT + 800 * DAY))
        self.assertIsNone(seed[new]["due"])
        self.assertEqual(seed[home]["due"], iso(CRT + 710 * DAY))

    def test_missing_last_review_time_falls_back_to_rated_review_history(
        self,
    ) -> None:
        c = self.collection
        reviewed_at = CRT + 600 * DAY + 3_600
        # Older Anki versions keep the FSRS memory state without `lrt`.
        legacy = c.card(1, ctype=2, queue=2, due=650, data={"s": 20.0, "d": 5.0})
        c.revlog(1, CRT + 500 * DAY, ease=3, rtype=1)
        c.revlog(1, reviewed_at, ease=3, rtype=1)
        # A later manual reschedule (Set Due Date) is not a review.
        c.revlog(1, reviewed_at + DAY, ease=0, rtype=4)
        # A stored `lrt` stays authoritative.
        explicit_at = CRT + 610 * DAY
        explicit = c.card(
            2,
            ctype=2,
            queue=2,
            due=660,
            data={"s": 20.0, "d": 5.0, "lrt": explicit_at},
        )
        c.revlog(2, explicit_at - DAY, ease=3, rtype=1)
        new = c.card(3, ctype=0, queue=0, due=4)
        never_rated = c.card(4, ctype=2, queue=2, due=670, data={"s": 9.0, "d": 4.0})
        _, _, seed, _ = c.payloads()

        self.assertEqual(seed[legacy]["last_review"], iso(reviewed_at))
        self.assertEqual(seed[explicit]["last_review"], iso(explicit_at))
        self.assertIsNone(seed[new]["last_review"])
        self.assertIsNone(seed[never_rated]["last_review"])

    def test_filtered_practice_without_rescheduling_is_not_the_last_review(
        self,
    ) -> None:
        c = self.collection
        reviewed_at = CRT + 600 * DAY
        # Practice in a filtered deck with rescheduling off logs a type 3
        # entry with factor 0 and leaves the FSRS memory state unchanged.
        crammed = c.card(1, ctype=2, queue=2, due=640, data={"s": 20.0, "d": 5.0})
        c.revlog(1, reviewed_at, ease=3, rtype=1, factor=2500)
        c.revlog(1, reviewed_at + 5 * DAY, ease=3, rtype=3, factor=0)
        # Older schedulers logged rescheduling filtered reviews as type 3
        # with the card's ease; those did move the memory state.
        rescheduled_early = c.card(
            2, ctype=2, queue=2, due=640, data={"s": 20.0, "d": 5.0}
        )
        c.revlog(2, reviewed_at + 2, ease=3, rtype=1, factor=2500)
        c.revlog(2, reviewed_at + 5 * DAY + 2, ease=3, rtype=3, factor=2500)
        # "Rescheduled" entries (type 5) are not reviews either.
        rescheduled = c.card(3, ctype=2, queue=2, due=640, data={"s": 20.0, "d": 5.0})
        c.revlog(3, reviewed_at + 3, ease=3, rtype=2, factor=2500)
        c.revlog(3, reviewed_at + 5 * DAY + 3, ease=3, rtype=5, factor=2500)
        _, _, seed, _ = c.payloads()

        self.assertEqual(seed[crammed]["last_review"], iso(reviewed_at))
        self.assertEqual(
            seed[rescheduled_early]["last_review"], iso(reviewed_at + 5 * DAY + 2)
        )
        self.assertEqual(seed[rescheduled]["last_review"], iso(reviewed_at + 3))


class FakeResponse:
    def __init__(self, data):
        self.data = data


class FakeQuery:
    def __init__(self, server: "FakeSupabase", table: str) -> None:
        self.server = server
        self.table_name = table
        self.action = None
        self.payload = None
        self.columns = None
        self.on_conflict = None
        self.filters = []
        self.order_by = None
        self.start = 0
        self.stop = None

    def select(self, columns):
        self.action, self.columns = "select", columns
        return self

    def upsert(self, rows, on_conflict, ignore_duplicates=False):
        self.action, self.payload, self.on_conflict = "upsert", rows, on_conflict
        self.ignore_duplicates = ignore_duplicates
        return self

    def insert(self, row):
        self.action, self.payload = "insert", row
        return self

    def update(self, values):
        self.action, self.payload = "update", values
        return self

    def eq(self, column, value):
        self.filters.append(lambda row: row.get(column) == value)
        return self

    def gt(self, column, value):
        self.filters.append(lambda row: row.get(column) > value)
        return self

    def in_(self, column, values):
        values = set(values)
        self.filters.append(lambda row: row.get(column) in values)
        return self

    def order(self, column, desc=False):
        self.order_by = (column, desc)
        return self

    def range(self, start, end):
        self.start, self.stop = start, end + 1
        return self

    def limit(self, count):
        self.start, self.stop = 0, count
        return self

    def execute(self):
        return FakeResponse(self.server.run(self))


class FakeSupabase:
    """PostgREST over a heap: unordered reads return physical order, and an
    updated row's new version is written at the end of the heap."""

    def __init__(self, *, max_rows: int = 1000) -> None:
        self.max_rows = max_rows
        self.tables = {"decks": [], "notes": [], "cards": [], "user_settings": []}
        self.next_id = {name: 1 for name in self.tables}
        self.after_select = None
        self.before_write = None
        self.updates = []

    def table(self, name):
        return FakeQuery(self, name)

    def add(self, table, row):
        row = {"id": self.next_id[table], **row}
        self.next_id[table] = row["id"] + 1
        self.tables[table].append(row)
        return row

    def rewrite(self, table, row, values):
        heap = self.tables[table]
        heap.remove(row)
        row.update(values)
        heap.append(row)

    def run(self, query: FakeQuery):
        heap = self.tables[query.table_name]
        if query.action == "select":
            rows = [row for row in heap if all(f(row) for f in query.filters)]
            if query.order_by:
                column, desc = query.order_by
                rows.sort(key=lambda row: row[column], reverse=desc)
            stop = len(rows) if query.stop is None else query.stop
            stop = min(stop, query.start + self.max_rows)
            columns = query.columns.split(",")
            page = [{c: row.get(c) for c in columns} for row in rows[query.start : stop]]
            if self.after_select:
                self.after_select(query, page)
            return page
        if self.before_write:
            self.before_write(query)
        if query.action == "insert":
            return [self.add(query.table_name, dict(query.payload))]
        if query.action == "upsert":
            keys = query.on_conflict.split(",")
            for incoming in query.payload:
                match = next(
                    (r for r in heap if all(r.get(k) == incoming[k] for k in keys)),
                    None,
                )
                if match is None:
                    self.add(query.table_name, dict(incoming))
                elif not query.ignore_duplicates:
                    self.rewrite(query.table_name, match, incoming)
            return []
        if query.action == "update":
            self.updates.append((query.table_name, query.payload))
            for row in [r for r in heap if all(f(r) for f in query.filters)]:
                self.rewrite(query.table_name, row, query.payload)
            return []
        raise AssertionError(query.action)


class FetchAllTest(unittest.TestCase):
    def test_reads_every_row_through_a_lower_server_cap(self) -> None:
        sb = FakeSupabase(max_rows=250)
        for i in range(600):
            sb.add("cards", {"user_id": "u", "guid": f"g{i}", "cloud_seen": True})

        rows = importer._fetch_all(sb, "cards", "guid", user_id="u", cloud_seen=True)

        self.assertEqual(sorted(r["guid"] for r in rows), sorted(f"g{i}" for i in range(600)))


class RunTest(unittest.TestCase):
    RECALL_STATE = {
        "stability": 41.0,
        "difficulty": 6.5,
        "state": 2,
        "due": "2026-12-01T00:00:00+00:00",
        "reps": 30,
        "lapses": 2,
        "last_review": "2026-10-20T09:00:00+00:00",
        "cloud_seen": True,
    }

    def test_reviewed_cards_keep_recall_scheduling_while_the_app_studies(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            collection = Collection(root / "collection.anki2")
            sb = FakeSupabase()
            count = 1001  # more than one 1000-row page
            for cid in range(1, count + 1):
                guid = collection.card(
                    cid, ctype=2, queue=2, due=100, data={"s": 3.0, "d": 9.0}
                )
                note = sb.add("notes", {"user_id": importer.USER_ID, "guid": guid})
                sb.add(
                    "cards",
                    {
                        "user_id": importer.USER_ID,
                        "guid": guid,
                        "note_id": note["id"],
                        "deleted": False,
                        "suspended": False,
                        **self.RECALL_STATE,
                    },
                )
            collection.con.commit()
            collection.con.close()

            # The phone rates the first card while the importer is between
            # pages of its "already reviewed in Recall" read.
            def phone_reviews_first_card(query, page):
                if (
                    query.table_name == "cards"
                    and query.columns.split(",")[-1] == "guid"
                    and page
                    and query.start == 0
                ):
                    sb.after_select = None
                    first = sb.tables["cards"][0]
                    sb.rewrite("cards", first, {"reps": 31})

            sb.after_select = phone_reviews_first_card
            with (
                mock.patch.object(importer, "LIVE_DB", str(collection.path)),
                mock.patch.object(tempfile, "tempdir", str(root)),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                importer.run(sb)

            for row in sb.tables["cards"]:
                with self.subTest(guid=row["guid"]):
                    self.assertEqual(row["stability"], 41.0)
                    self.assertEqual(row["difficulty"], 6.5)
                    self.assertEqual(row["due"], self.RECALL_STATE["due"])
                    self.assertEqual(
                        row["last_review"], self.RECALL_STATE["last_review"]
                    )
                    self.assertGreaterEqual(row["reps"], 30)

    def _cloud_card(self, sb, guid, **state):
        note = sb.add("notes", {"user_id": importer.USER_ID, "guid": guid})
        return sb.add(
            "cards",
            {
                "user_id": importer.USER_ID,
                "guid": guid,
                "note_id": note["id"],
                "deleted": False,
                "suspended": False,
                **state,
            },
        )

    def _run(self, root, collection, sb):
        collection.con.commit()
        collection.con.close()
        with (
            mock.patch.object(importer, "LIVE_DB", str(collection.path)),
            mock.patch.object(tempfile, "tempdir", str(root)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            importer.run(sb)

    def test_review_landing_before_the_seed_write_is_not_overwritten(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            collection = Collection(root / "collection.anki2")
            sb = FakeSupabase()
            guid = collection.card(
                1, ctype=2, queue=2, due=100, data={"s": 3.0, "d": 9.0}
            )
            # Recall has not reviewed it yet, and the desktop has moved on.
            card = self._cloud_card(
                sb,
                guid,
                stability=1.0,
                difficulty=5.0,
                state=0,
                due=None,
                reps=0,
                lapses=0,
                last_review=None,
                cloud_seen=False,
            )

            # The phone's first review commits after every importer read and
            # before its first card write.
            def phone_reviews(query):
                if query.table_name == "cards":
                    sb.before_write = None
                    sb.rewrite("cards", card, dict(self.RECALL_STATE))

            sb.before_write = phone_reviews
            self._run(root, collection, sb)

            (row,) = sb.tables["cards"]
            for column, value in self.RECALL_STATE.items():
                with self.subTest(column=column):
                    self.assertEqual(row[column], value)
            self.assertEqual(row["note_id"], card["note_id"])

    def test_unreviewed_cards_still_follow_desktop_scheduling(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            collection = Collection(root / "collection.anki2")
            sb = FakeSupabase()
            data = {"s": 3.14159265, "d": 9.0, "lrt": CRT + 90 * DAY}
            fresh = collection.card(1, ctype=2, queue=2, due=100, data=data)
            moved = collection.card(2, ctype=2, queue=2, due=100, data=data)
            same = collection.card(3, ctype=2, queue=2, due=100, data=data)
            reviewed = collection.card(4, ctype=2, queue=2, due=100, data=data)
            # PostgREST echoes timestamps and real columns in its own format.
            desktop = {
                "stability": 3.1415927,
                "difficulty": 9.0,
                "state": 2,
                "due": iso(CRT + 100 * DAY).replace("+00:00", "Z"),
                "reps": 3,
                "lapses": 0,
                "last_review": iso(CRT + 90 * DAY),
                "cloud_seen": False,
            }
            self._cloud_card(sb, moved, **{**desktop, "stability": 1.0, "reps": 1})
            self._cloud_card(sb, same, **desktop)
            self._cloud_card(sb, reviewed, **self.RECALL_STATE)
            self._run(root, collection, sb)

            rows = {row["guid"]: row for row in sb.tables["cards"]}
            for guid in (fresh, moved, same):
                with self.subTest(guid=guid):
                    self.assertAlmostEqual(rows[guid]["stability"], 3.14159265)
                    self.assertEqual(rows[guid]["reps"], 3)
                    self.assertEqual(rows[guid]["state"], 2)
            self.assertEqual(rows[fresh]["due"], iso(CRT + 100 * DAY))
            self.assertEqual(rows[reviewed]["stability"], 41.0)
            self.assertEqual(rows[reviewed]["reps"], 30)
            # Only the card whose desktop scheduling changed is rewritten.
            scheduled = [
                payload for table, payload in sb.updates if "stability" in payload
            ]
            self.assertEqual(len(scheduled), 1)


if __name__ == "__main__":
    unittest.main()

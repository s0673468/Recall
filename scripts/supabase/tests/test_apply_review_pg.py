"""Executes the checked-in Supabase migrations in a disposable local PostgreSQL.

Nothing here reaches a Supabase project. A throwaway cluster is created in a
temporary directory, listens only on a private Unix socket, and is stopped and
deleted afterwards. A small stand-in provides the Supabase pieces the
migrations reference: the ``anon``/``authenticated`` roles, ``auth.users`` and
``auth.uid()`` (read from ``request.jwt.claim.sub`` as Supabase does).

PostgreSQL binaries come from ``RECALL_PG_BIN``, else ``pg_config --bindir``
or ``initdb`` on PATH. Without them the suite is skipped, unless
``RECALL_REQUIRE_PG=1`` makes that a failure.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SUPABASE = ROOT / "scripts" / "supabase"
MIGRATIONS = sorted((SUPABASE / "migrations").glob("[0-9][0-9][0-9]_*.sql"))
OWNER = "a0000000-0000-4000-8000-000000000001"  # 000's review_log default
OTHER = "b0000000-0000-4000-8000-000000000002"
SIGNATURE = (
    "public.apply_review(bigint,text,smallint,timestamp with time zone,real,"
    "real,timestamp with time zone,smallint,boolean,integer,text,text)"
)

# Roles are cluster-wide; the rest is created in each database.
SUPABASE_ROLES = "create role anon nologin; create role authenticated nologin;"
SUPABASE_STAND_IN = f"""
create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
insert into auth.users (id) values ('{OWNER}'), ('{OTHER}');
"""

FIXTURE = f"""
insert into public.notes (id, user_id, guid, deck_id, mid, front, back)
values (1, '{OWNER}', 'n1', 1, 1, 'invented front 1', 'invented back 1'),
       (2, '{OWNER}', 'n2', 1, 1, 'invented front 2', 'invented back 2'),
       (3, '{OTHER}', 'n3', 1, 1, 'invented front 3', 'invented back 3');
insert into public.cards (id, user_id, note_id, guid, state, last_review)
values (1, '{OWNER}', 1, 'c1', 2, '2026-10-01T00:00:00Z'),
       (2, '{OWNER}', 2, 'c2', 2, '2026-10-01T00:00:00Z'),
       (3, '{OTHER}', 3, 'c3', 2, '2026-10-01T00:00:00Z');
"""


def review(card_id, event_id, rating_at="2026-10-16T12:00:00Z", stability=20):
    """One apply_review call, with the argument types PostgREST resolves."""
    return (
        f"select public.apply_review({card_id}::bigint, 'g', 3::smallint, "
        f"'{rating_at}'::timestamptz, {stability}::real, 5::real, "
        f"'{rating_at}'::timestamptz + interval '10 days', 2::smallint, false, "
        f"1000, 'android', '{event_id}')"
    )


def _pg_bin():
    configured = os.environ.get("RECALL_PG_BIN")
    if configured:
        return Path(configured)
    pg_config = shutil.which("pg_config")
    if pg_config:
        result = subprocess.run([pg_config, "--bindir"], capture_output=True, text=True)
        candidate = Path(result.stdout.strip())
        if result.returncode == 0 and (candidate / "initdb").exists():
            return candidate
    initdb = shutil.which("initdb")
    return Path(initdb).parent if initdb else None


class SqlError(Exception):
    pass


class ApplyReviewPostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bin = _pg_bin()
        if cls.bin is None or not (cls.bin / "initdb").exists():
            if os.environ.get("RECALL_REQUIRE_PG") == "1":
                raise RuntimeError("RECALL_REQUIRE_PG=1 but no PostgreSQL binaries found")
            raise unittest.SkipTest("PostgreSQL binaries unavailable; set RECALL_PG_BIN")
        cls.temp = tempfile.mkdtemp(prefix="recall-pg-")
        cls.data = Path(cls.temp) / "data"
        cls.socket = Path(cls.temp) / "sock"
        cls.socket.mkdir()
        try:
            cls._run(["initdb", "-D", str(cls.data), "-U", "postgres", "--auth=trust",
                      "-E", "UTF8", "--no-sync", "--no-instructions"])
            cls._run(["pg_ctl", "-D", str(cls.data), "-l", str(Path(cls.temp) / "pg.log"),
                      "-w", "-o", f"-k {cls.socket} -c listen_addresses='' -c fsync=off",
                      "start"])
            cls._started = True
            cls.psql("postgres", SUPABASE_ROLES)
            cls.psql("postgres", "create database recall_pre008")
            cls.psql("postgres", "create database recall_template")
            for db, migrations in (("recall_pre008", MIGRATIONS[:-1]),
                                   ("recall_template", MIGRATIONS)):
                cls.psql(db, SUPABASE_STAND_IN)
                for path in migrations:
                    cls.psql(db, file=path)
                cls.psql(db, FIXTURE)
            # Re-running the newest migration must be harmless.
            cls.psql("recall_template", file=MIGRATIONS[-1])
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "_started", False):
            subprocess.run([str(cls.bin / "pg_ctl"), "-D", str(cls.data), "-m", "immediate",
                            "-w", "stop"], capture_output=True)
            cls._started = False
        if getattr(cls, "temp", None):
            shutil.rmtree(cls.temp, ignore_errors=True)
            cls.temp = None

    @classmethod
    def _run(cls, args):
        result = subprocess.run([str(cls.bin / args[0]), *args[1:]], capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"{args[0]} failed: {result.stderr or result.stdout}")
        return result

    @classmethod
    def psql(cls, db, sql=None, file=None, as_user=None):
        """Run SQL as the superuser, or as ``authenticated`` with a JWT subject."""
        if as_user is not None:
            sql = (f"begin; set local role authenticated; "
                   f"set local request.jwt.claim.sub = '{as_user}'; {sql}; commit;")
        args = [str(cls.bin / "psql"), "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
                "-v", "VERBOSITY=verbose", "-h", str(cls.socket), "-U", "postgres", "-d", db]
        args += ["-f", str(file)] if file else ["-c", sql]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode != 0:
            raise SqlError(result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.db = f"recall_{self.id().rsplit('.', 1)[-1]}"[:63]
        self.psql("postgres", f"create database {self.db} template recall_template")
        self.addCleanup(self.psql, "postgres", f"drop database {self.db}")

    def owner(self, sql):
        return self.psql(self.db, sql, as_user=OWNER)

    def scalar(self, sql):
        return self.psql(self.db, sql)

    def card(self, card_id):
        return self.scalar(
            f"select reps, lapses, stability, last_review = '2026-10-16T12:00:00Z' "
            f"from public.cards where id = {card_id}")

    def test_before_008_a_hard_deleted_card_fails_every_retry(self):
        self.psql("recall_pre008", "delete from public.cards where id = 1")
        for _ in range(2):
            with self.assertRaises(SqlError) as raised:
                self.psql("recall_pre008", review(1, "ev-pre"), as_user=OWNER)
            self.assertIn("23503", str(raised.exception))

    def test_hard_deleted_card_review_is_acknowledged_and_later_reviews_apply(self):
        self.scalar("delete from public.cards where id = 1")
        # The outbox sends oldest-first: the orphan, then a live card.
        self.assertEqual(self.owner(review(1, "ev-orphan")), "0")
        live_id = int(self.owner(review(2, "ev-live")))
        self.assertGreater(live_id, 0)
        self.assertEqual(self.card(2), "1|0|20|t")
        # A lost ACK replays both events; neither changes anything.
        self.assertEqual(self.owner(review(1, "ev-orphan")), "0")
        self.assertEqual(self.owner(review(2, "ev-live")), str(live_id))
        self.assertEqual(self.card(2), "1|0|20|t")
        self.assertEqual(
            self.scalar("select count(*) from public.review_log where client_event_id = 'ev-orphan'"),
            "0")
        self.assertEqual(self.scalar("select count(*) from public.review_log"), "1")

    def test_ownership_is_checked_before_a_missing_card_is_acknowledged(self):
        self.scalar("delete from public.cards where id = 1")
        # The other account cannot write the owner's log, deleted card or not.
        for card_id in (1, 2):
            with self.assertRaises(SqlError) as raised:
                self.psql(self.db, review(card_id, f"ev-other-{card_id}"), as_user=OTHER)
            self.assertIn("42501", str(raised.exception))
        self.assertEqual(self.scalar("select count(*) from public.review_log"), "0")

    def test_card_hidden_by_rls_keeps_the_006_log_without_merge(self):
        log_id = int(self.owner(review(3, "ev-hidden")))
        self.assertGreater(log_id, 0)
        self.assertEqual(self.owner(review(3, "ev-hidden")), str(log_id))
        self.assertEqual(self.card(3), "0|0|0|f")

    def test_live_card_merge_and_idempotency_are_unchanged(self):
        first = self.owner(review(2, "ev-1", "2026-10-16T12:00:00Z", 20))
        self.assertEqual(self.owner(review(2, "ev-1", "2026-10-16T12:00:00Z", 99)), first)
        self.assertEqual(self.card(2), "1|0|20|t")
        # Older review counts but does not rewind; a tie keeps the first schedule.
        self.owner(review(2, "ev-2", "2026-10-02T00:00:00Z", 2))
        self.owner(review(2, "ev-3", "2026-10-16T12:00:00Z", 55))
        self.assertEqual(self.card(2), "3|0|20|t")
        self.assertEqual(self.scalar("select count(*) from public.review_log where card_id = 2"), "3")

    def test_null_event_id_is_still_rejected(self):
        with self.assertRaises(SqlError) as raised:
            self.owner(review(2, "x").replace("'x'", "null"))
        self.assertIn("apply_review requires a client_event_id", str(raised.exception))

    def test_function_security_and_grants_are_unchanged(self):
        self.assertEqual(
            self.scalar(f"select prosecdef, proconfig from pg_proc where oid = '{SIGNATURE}'::regprocedure"),
            'f|{"search_path=public, pg_temp"}')
        self.assertEqual(
            self.scalar(f"select has_function_privilege('authenticated', '{SIGNATURE}', 'EXECUTE')"),
            "t")

    def test_repository_verify_scripts_pass(self):
        self.assertIn("VERIFY OK: Recall schema contract",
                      self.psql(self.db, file=SUPABASE / "verify" / "verify_schema.sql"))
        with self.assertRaises(SqlError) as raised:
            self.psql(self.db, file=SUPABASE / "verify" / "verify_apply_review.sql")
        self.assertIn("VERIFY OK (rolled back; card", str(raised.exception))
        self.assertEqual(self.scalar("select count(*) from public.review_log"), "0")

    def test_verify_scripts_report_a_project_without_008(self):
        with self.assertRaises(SqlError) as raised:
            self.psql("recall_pre008", file=SUPABASE / "verify" / "verify_schema.sql")
        self.assertIn("apply_review predates 008", str(raised.exception))
        with self.assertRaises(SqlError) as raised:
            self.psql("recall_pre008", file=SUPABASE / "verify" / "verify_apply_review.sql")
        self.assertIn("VERIFY FAILED: E:fk_blocks_outbox", str(raised.exception))


if __name__ == "__main__":
    unittest.main()

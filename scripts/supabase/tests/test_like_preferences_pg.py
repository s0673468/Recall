"""Synthetic like/count/rollback contracts in the existing disposable PG harness."""
import unittest
import test_apply_review_pg as pg


class LikePreferencesPostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pg.ApplyReviewPostgresTests.setUpClass()

    @classmethod
    def tearDownClass(cls):
        pg.ApplyReviewPostgresTests.tearDownClass()

    def setUp(self):
        self.runner = pg.ApplyReviewPostgresTests
        self.db = 'recall_likes_test'
        self.runner.psql('postgres', f'create database {self.db} template recall_template')
        self.addCleanup(self.runner.psql, 'postgres', f'drop database {self.db}')

    def sql(self, value):
        return self.runner.psql(self.db, value, as_user=pg.OWNER)

    def test_likes_leave_counts_unchanged_and_dislikes_still_hide(self):
        before = self.sql('select * from public.deck_counts()')
        self.sql("insert into public.note_flags (card_id,guid,reason,flagged_at,client_event_id) "
                 "values (1,'synthetic','like',now(),'synthetic-like')")
        self.assertEqual(self.sql('select * from public.deck_counts()'), before)
        self.sql("insert into public.note_flags (card_id,guid,reason,flagged_at) "
                 "values (1,'synthetic','dislike',now())")
        self.assertNotEqual(self.sql('select * from public.deck_counts()'), before)
        self.sql("update public.note_flags set status='dismissed' where reason='dislike'")
        self.assertEqual(self.sql('select * from public.deck_counts()'), before)

    def test_rollback_refuses_all_like_history_without_deleting_rows(self):
        rollback = pg.SUPABASE / 'rollback' / '010_restore_flag_reasons.sql'
        self.sql("insert into public.note_flags (card_id,guid,reason,flagged_at,status) "
                 "values (1,'synthetic','like',now(),'dismissed')")
        with self.assertRaisesRegex(pg.SqlError, 'like flags exist'):
            self.runner.psql(self.db, file=rollback)
        self.assertEqual(self.sql("select count(*) from public.note_flags where reason='like'"), '1')

    def test_rollback_without_likes_restores_the_previous_reason_set(self):
        rollback = pg.SUPABASE / 'rollback' / '010_restore_flag_reasons.sql'
        self.runner.psql(self.db, file=rollback)
        self.sql("insert into public.note_flags (card_id,guid,reason,flagged_at) "
                 "values (1,'synthetic','dislike',now())")
        with self.assertRaisesRegex(pg.SqlError, 'note_flags_reason_check'):
            self.sql("insert into public.note_flags (card_id,guid,reason,flagged_at) "
                     "values (1,'synthetic','like',now())")

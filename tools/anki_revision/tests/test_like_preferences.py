import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import anki_flags
import anki_garden_score as garden


class LikePreferencesTest(unittest.TestCase):
    def test_likes_do_not_change_lane_priority_or_order(self):
        notes = [
            dict(nid=i, guid=f'g{i}', front='Synthetic question?', back='Answer.', reps=10, lapses=i, ivl=20)
            for i in range(1, 4)
        ]
        baseline = garden.rank_notes(notes)
        for flags in ([dict(nid=1, reason='like')], {'flags': [dict(guid='g1', reason='like', status='open')]}):
            self.assertEqual(garden.rank_notes(notes, flags=flags), baseline)
        mixed = garden.rank_notes(notes, flags=[dict(nid=1, reason='like'), dict(nid=2, reason='dislike')])
        self.assertEqual(mixed[0]['nid'], 2)
        self.assertEqual(mixed[0]['lane'], 'flagged')
        self.assertEqual(next(row for row in mixed if row['nid'] == 1)['lane'], 'scored')

    def test_cloud_flag_projection_keeps_reason_and_excludes_likes(self):
        query = mock.MagicMock()
        for name in ('select', 'eq', 'neq', 'range'):
            getattr(query, name).return_value = query
        query.execute.return_value.data = []
        client = mock.Mock()
        client.table.return_value = query
        with mock.patch.dict(sys.modules, {'supabase': mock.Mock(create_client=mock.Mock(return_value=client))}):
            garden.fetch_cloud_signals(dict(SUPABASE_URL='https://fixture.invalid', SUPABASE_SERVICE_KEY='fixture', SUPABASE_USER_ID='synthetic'))
        query.select.assert_any_call('guid,reason,status')
        query.eq.assert_any_call('status', 'open')
        query.neq.assert_called_once_with('reason', 'like')

    def flags(self):
        return [dict(id=i, guid=f'g{i}', reason=reason, flagged_at='2026-10-01T00:00:00Z', device='test')
                for i, reason in enumerate(('like', 'dislike', 'delete'), 1)]

    def test_list_groups_likes_and_supports_reason_filter(self):
        for reason in (None, 'like'):
            output = io.StringIO()
            with mock.patch.object(anki_flags, 'creds', return_value=('fixture', 'fixture')), mock.patch.object(anki_flags, 'req', return_value=self.flags()) as request, mock.patch.object(anki_flags.os.path, 'exists', return_value=False), contextlib.redirect_stdout(output):
                anki_flags.cmd_list(Namespace(reason=reason, json=False, nids_file=None))
            self.assertIn('Liked (keep this style) (1)', output.getvalue())
            self.assertIn('Revision flags (2)', output.getvalue())
            if reason:
                self.assertEqual(request.call_args.kwargs['params']['reason'], 'eq.like')

    def test_nid_export_never_sends_likes_to_revision(self):
        con = sqlite3.connect(':memory:')
        con.executescript('CREATE TABLE notes(id, guid, flds); CREATE TABLE cards(nid, did);')
        for i in range(1, 4):
            con.execute('INSERT INTO notes VALUES (?, ?, ?)', (i, f'g{i}', 'Synthetic?'))
            con.execute('INSERT INTO cards VALUES (?, 1)', (i,))
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / 'queue.json')
            with mock.patch.object(anki_flags, 'creds', return_value=('fixture', 'fixture')), mock.patch.object(anki_flags, 'req', return_value=self.flags()), mock.patch.object(anki_flags.os.path, 'exists', return_value=True), mock.patch.object(anki_flags.ac, 'connect', return_value=con), mock.patch.object(anki_flags.ac, 'deck_name_to_id', return_value={'Synthetic': 1}), contextlib.redirect_stdout(io.StringIO()):
                anki_flags.cmd_list(Namespace(reason=None, json=False, nids_file=path))
            self.assertEqual(json.loads(Path(path).read_text()), [2, 3])
        con.close()

    def test_weekly_close_never_mutates_likes(self):
        for status in ('resolved', 'dismissed'):
            with mock.patch.object(anki_flags, 'creds', return_value=('fixture', 'fixture')), mock.patch.object(anki_flags, 'req', return_value=[{'id': 2}]) as request, contextlib.redirect_stdout(io.StringIO()):
                anki_flags.cmd_close(Namespace(flag_id=2, resolution='Synthetic correction'), status)
            params = request.call_args.kwargs['params']
            self.assertEqual(params, {'id': 'eq.2', 'status': 'eq.open', 'reason': 'neq.like'})
            self.assertEqual(request.call_args.kwargs['body']['status'], status)


if __name__ == '__main__':
    unittest.main()

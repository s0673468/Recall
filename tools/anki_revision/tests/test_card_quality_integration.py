"""Synthetic card-quality ranking regressions; never read a live collection."""
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


class CardQualityGardenTest(unittest.TestCase):
    def notes(self):
        return [dict(nid=i, guid=f'fixture-{i}', front='Synthetic?', back='Answer.',
                     reps=10, lapses=0, ivl=30, card_ids=[1000+i]) for i in range(1, 42)]

    def prediction(self, quality=1, forget=0, liked=False):
        return dict(quality_score=quality, forget_score=forget,
                    top_reasons=['liked_keep_style'] if liked else [])

    def test_absent_scores_preserve_full_baseline(self):
        notes = self.notes()
        baseline = garden.rank_notes(notes)
        self.assertEqual(garden.rank_notes(notes, quality_scores=None), baseline)
        self.assertEqual(garden.rank_notes(notes, quality_scores={}), baseline)

    def test_low_quality_and_high_forget_raise_priority_independently(self):
        notes = self.notes()
        baseline = {row['nid']: row for row in garden.rank_notes(notes, limit=40)}
        for quality, forget in ((0, 0), (1, 1)):
            scores = {1030: self.prediction(quality, forget)}
            queue = garden.rank_notes(notes, quality_scores=scores)
            self.assertEqual(queue[0]['nid'], 30)
            self.assertGreater(queue[0]['priority'], baseline[30]['priority'])
            self.assertIn('local_card_quality_model', queue[0]['reasons'])
            self.assertEqual(len(queue), 30)

    def test_corrective_flags_keep_first_lane_and_likes_are_protected(self):
        flags = [dict(nid=40, reason='wrong'), dict(nid=31, reason='like'),
                 dict(guid='fixture-32', reason='like'), dict(nid=33, reason='like'),
                 dict(nid=33, reason='delete')]
        scores = {1030: self.prediction(0, 1, liked=True),
                  1031: self.prediction(0, 1), 1032: self.prediction(0, 1),
                  1033: self.prediction(0, 1), 1034: self.prediction(0, 1)}
        queue = garden.rank_notes(self.notes(), quality_scores=scores, flags=flags, limit=40)
        self.assertEqual(queue[0]['nid'], 40)
        self.assertEqual(queue[0]['lane'], 'flagged')
        self.assertTrue({30, 31, 32, 33}.isdisjoint(row['nid'] for row in queue))
        self.assertEqual(queue[1]['nid'], 34)

    def test_sibling_cards_use_strongest_signal_and_keep_liked_note(self):
        notes = self.notes()
        notes[29]['card_ids'] = [1030, 9000]
        scores = {1030: self.prediction(1, 0), 9000: self.prediction(0, 1)}
        self.assertEqual(garden.rank_notes(notes, quality_scores=scores)[0]['nid'], 30)
        scores[1030] = self.prediction(1, 0, liked=True)
        self.assertNotIn(30, [row['nid'] for row in garden.rank_notes(notes, quality_scores=scores, limit=40)])

    def test_json_csv_loading_and_invalid_inputs_do_not_echo_content(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / 'scores.json'
            path.write_text(json.dumps([dict(card_id=1, **self.prediction(0.1, 0.8, True))]))
            self.assertEqual(garden.load_quality_scores(path)[1], self.prediction(0.1, 0.8, True))
            path = root / 'scores.csv'
            path.write_text('card_id,quality_score,forget_score,top_reasons\n1,0.1,0.8,liked_keep_style;problem_association:lapses\n')
            self.assertEqual(garden.load_quality_scores(path)[1], self.prediction(0.1, 0.8, True))
            self.assertIsNone(garden.load_quality_scores(None))
            path = root / 'scores.json'
            for bad in ([dict(card_id=1, **self.prediction(2, 0))],
                        [dict(card_id=True, **self.prediction())],
                        [dict(card_id=1, **self.prediction(float('nan'), 0))],
                        [dict(card_id=1, **self.prediction())]*2,
                        [{'card_id': 'SYNTHETIC_CONTENT_STAYS_LOCAL'}]):
                path.write_text(json.dumps(bad))
                with self.assertRaisesRegex(garden.GardenError, '^invalid local card quality scores$'):
                    garden.load_quality_scores(path)
            path.write_text(json.dumps([dict(card_id=1, **self.prediction(), extra='SYNTHETIC_CONTENT_STAYS_LOCAL')]))
            self.assertNotIn('SYNTHETIC_CONTENT_STAYS_LOCAL', json.dumps(garden.load_quality_scores(path)))

    def test_cli_joins_cloud_card_ids_to_local_nids_explicitly(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db, scores, mapping, out = [root / n for n in ('fixture.db', 'scores.json', 'map.json', 'queue.json')]
            con = sqlite3.connect(db)
            con.executescript('CREATE TABLE notes(id,guid,tags,flds); CREATE TABLE cards(nid,reps,lapses,ivl);')
            for note in self.notes():
                con.execute('INSERT INTO notes VALUES (?,?,?,?)',
                            (note['nid'], note['guid'], '', 'Synthetic?\x1fAnswer.'))
                con.execute('INSERT INTO cards VALUES (?,10,0,30)', (note['nid'],))
            con.commit()
            con.close()
            scores.write_text(json.dumps([dict(card_id=1030, **self.prediction(0, 1))]))
            mapping.write_text(json.dumps([dict(card_id=1030, nid=30)]))
            args = ['anki_garden_score.py', '--no-cloud', '--db', str(db), '--out', str(out),
                    '--quality-scores', str(scores), '--quality-card-map', str(mapping)]
            with mock.patch.object(sys, 'argv', args), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(garden.main(), 0)
            self.assertEqual(json.loads(out.read_text())['queue'][0]['nid'], 30)
            mapping.write_text('[]')
            with mock.patch.object(sys, 'argv', args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                garden.main()
            self.assertEqual(error.exception.code, 1)
            mapping.write_text(json.dumps([dict(card_id=1030, nid=999999)]))
            with mock.patch.object(sys, 'argv', args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                garden.main()
            self.assertEqual(error.exception.code, 1)
            with mock.patch.object(sys, 'argv', args[:-2]), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                garden.main()
            self.assertEqual(error.exception.code, 1)

    def test_id_map_rejects_ambiguous_duplicates_and_unknown_ids(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'map.json'
            for rows in ([dict(card_id=1, nid=1), dict(card_id=1, nid=2)],
                         [dict(card_id='1', nid=1)], [dict(card_id=1, nid=0)]):
                path.write_text(json.dumps(rows))
                with self.assertRaises(garden.GardenError):
                    garden.load_quality_card_map(path)
            path.write_text(json.dumps([dict(card_id=1, nid=5), dict(card_id=2, nid=5)]))
            self.assertEqual(garden.load_quality_card_map(path), {5: [1, 2]})


if __name__ == '__main__':
    unittest.main()

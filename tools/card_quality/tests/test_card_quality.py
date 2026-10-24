import contextlib
import copy
import io
import json
import math
import os
from pathlib import Path
import socket
import sqlite3
import stat
import tempfile
import unittest
from unittest import mock

from tools.card_quality import adapter, cli, features, model
from tools.card_quality.synthetic import generate


SENTINEL = 'SYNTHETIC_CONTENT_MUST_STAY_LOCAL'


def load_fixture(root, payload=None, **kwargs):
    path = root / 'source.json'
    path.write_text(json.dumps(payload if payload is not None else generate(cards_per_deck=16)))
    return adapter.load_export(path, synthetic=True, **kwargs)


class FeatureTest(unittest.TestCase):
    def card(self, **kwargs):
        return dict(card_id=1, deck_id=1, front='One?', back='Two.', reviews=[],
                    label=None, label_reasons=[], liked=False, **kwargs)

    def metrics(self, cards):
        return [dict(zip(features.FEATURE_NAMES, row['x'])) for row in features.card_features(cards)]

    def test_shape_markup_readability_and_no_vocabulary(self):
        card = self.card()
        card.update(front='<p>What shape?</p><script>hidden words</script>',
                    back='<ul><li>{{c1::round}}</li></ul><table><tr><td>cell</td></tr></table>'
                         '<img src="ignored.png"> \\(x+1\\) {{c2::two}}')
        values = self.metrics([card])[0]
        self.assertEqual(values['front_words'], 2)
        self.assertEqual(values['front_chars'], len('What shape?'))
        self.assertEqual(values['cloze_count'], 2)
        for name in ('has_list', 'has_table', 'has_math', 'has_image'):
            self.assertEqual(values[name], 1)
        self.assertGreater(values['words_per_sentence'], 1)
        self.assertGreater(values['chars_per_word'], 1)
        self.assertNotIn('hidden', json.dumps(features.card_features([card])))

    def test_plain_list_math_and_front_back_ratio(self):
        card = self.card()
        card.update(front='Which?', back='- One\n- Two $x$')
        values = self.metrics([card])[0]
        self.assertEqual(values['has_list'], 1)
        self.assertEqual(values['has_math'], 1)
        self.assertAlmostEqual(values['front_back_ratio'], len('Which?') / len('- One - Two $x$'))

    def test_similarity_uses_only_same_deck_and_excludes_self(self):
        a, b, c = self.card(), self.card(), self.card()
        b.update(card_id=2, deck_id=2)
        c.update(card_id=3, front='Unrelated', back='invented')
        values = self.metrics([a, b, c])
        self.assertEqual([r['sibling_similarity'] for r in values], [0, 0, 0])
        b['deck_id'] = 1
        self.assertEqual([r['sibling_similarity'] for r in self.metrics([a, b])], [1, 1])

    def test_missing_values_are_distinct_from_zero_and_timing_is_median(self):
        missing, known = self.card(), self.card()
        known.update(card_id=2, difficulty=0, stability=0, lapses=0, reps=3,
                     reviews=[dict(rating=1, elapsed_ms=2000), dict(rating=3, elapsed_ms=6000),
                              dict(rating=3, elapsed_ms=None)])
        a, b = self.metrics([missing, known])
        for name in ('missing_difficulty', 'missing_stability', 'missing_reviews', 'missing_timing'):
            self.assertEqual(a[name], 1)
            self.assertEqual(b[name], 0)
        self.assertAlmostEqual(b['again_rate'], 1/3)
        self.assertEqual(b['answer_seconds'], 4)

    def test_forgetting_grows_with_difficulty_lapses_and_again(self):
        easy, hard = self.card(), self.card()
        easy.update(reps=20, lapses=0, difficulty=2, stability=100, reviews=[dict(rating=3)] * 20)
        hard.update(reps=20, lapses=12, difficulty=9, stability=1, reviews=[dict(rating=1)] * 20)
        self.assertLess(features.forget_score(easy), features.forget_score(hard))
        self.assertEqual(features.forget_score(self.card()), 0.25)
        self.assertTrue(0 <= features.forget_score(hard) <= 1)


class AdapterTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = generate(cards_per_deck=4)

    def test_opt_in_required_before_opening_any_source(self):
        with mock.patch.object(adapter, 'read_json') as read:
            for kwargs in ({}, dict(synthetic=True, real_data=True), dict(synthetic=True, anki_db='unused')):
                with self.assertRaises(features.QualityError):
                    adapter.load_export('not-opened', **kwargs)
            read.assert_not_called()

    def test_unmarked_source_requires_real_data_and_no_network(self):
        self.payload.pop('synthetic')
        path = self.root / 'source.json'
        path.write_text(json.dumps(self.payload))
        with self.assertRaises(features.QualityError):
            adapter.load_export(path, synthetic=True)
        with mock.patch.object(socket, 'socket', side_effect=AssertionError('network is forbidden')):
            self.assertEqual(len(adapter.load_export(path, real_data=True)), 16)

    def test_each_reason_conflicts_and_stale_flags(self):
        flag = self.payload['note_flags'][0]
        for reason in sorted(features.REASONS):
            flag['reason'] = reason
            row = load_fixture(self.root, self.payload)[0]
            self.assertEqual(row['label'], 0 if reason == 'like' else 1)
            self.assertEqual(row['label_reasons'], [reason])
        self.payload['note_flags'].append({**flag, 'reason': 'like'})
        row = load_fixture(self.root, self.payload)[0]
        self.assertIsNone(row['label'])
        self.assertTrue(row['liked'])
        for flag in self.payload['note_flags']:
            flag['status'] = 'resolved'
        self.assertTrue(all(r['label'] is None for r in load_fixture(self.root, self.payload)))

    def test_deleted_cards_and_notes_are_not_scored(self):
        self.payload['cards'][0]['deleted'] = True
        self.payload['notes'][1]['deleted'] = True
        self.assertEqual(len(load_fixture(self.root, self.payload)), 14)

    def test_rejects_bad_linkages_ratings_flags_numbers_and_mixed_accounts(self):
        for table, field, value in (
            ('review_log', 'guid', 'unlinked'), ('review_log', 'rating', 9),
            ('review_log', 'elapsed_ms', -1), ('cards', 'difficulty', math.nan),
            ('cards', 'stability', -3), ('cards', 'id', True),
            ('note_flags', 'reason', SENTINEL), ('note_flags', 'card_id', 999999),
            ('note_flags', 'status', SENTINEL),
        ):
            with self.subTest(table=table, field=field):
                bad = copy.deepcopy(self.payload)
                bad[table][0][field] = value
                with self.assertRaises(features.QualityError):
                    load_fixture(self.root, bad)
        self.payload['cards'][0]['user_id'] = 'synthetic-account-a'
        self.payload['cards'][1]['user_id'] = 'synthetic-account-b'
        with self.assertRaises(features.QualityError):
            load_fixture(self.root, self.payload)

    def test_anki_authoring_snapshot_is_read_only_and_keeps_cloud_scheduling(self):
        source = self.root / 'source.json'
        source.write_text(json.dumps(self.payload))
        db = self.root / 'synthetic.anki2'
        con = sqlite3.connect(db)
        con.execute('CREATE TABLE notes (id INTEGER, guid TEXT, flds TEXT)')
        con.executemany('INSERT INTO notes VALUES (?,?,?)',
                        [(1000+i, note['guid'], 'Local?\x1fSynthetic.') for i, note in enumerate(self.payload['notes'])])
        con.commit()
        con.close()
        before = db.read_bytes()
        rows = adapter.load_export(source, real_data=True, anki_db=db)
        self.assertEqual(rows[0]['nid'], 1000)
        values = dict(zip(features.FEATURE_NAMES, rows[0]['x']))
        self.assertEqual(values['back_words'], 1)
        self.assertEqual(values['difficulty'], self.payload['cards'][0]['difficulty'])
        self.assertEqual(db.read_bytes(), before)
        self.assertFalse(Path(str(db) + '-journal').exists())


class ModelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as temp:
            cls.rows = load_fixture(Path(temp))
        cls.fitted = model.train(cls.rows)

    def test_planted_signals_and_calibrated_held_out_predictions(self):
        evaluation = self.fitted['evaluation']
        self.assertEqual(evaluation['method'], 'nested-leave-one-deck-out')
        self.assertEqual(len(evaluation['folds']), 4)
        self.assertGreater(evaluation['aggregate']['auc'], 0.95)
        self.assertLess(evaluation['aggregate']['brier'], evaluation['prevalence_baseline']['brier'])
        self.assertLess(evaluation['aggregate']['ece'], 0.15)
        weights = dict(zip(features.FEATURE_NAMES, self.fitted['weights']))
        self.assertGreater(weights['back_words'], 0)
        self.assertGreater(weights['lapses'], 0)
        self.assertLess(weights['stability'], 0)
        explanation = ' '.join(model.explain(self.fitted, limit=22))
        self.assertIn('shorter answers', explanation)
        self.assertIn('fewer lapses', explanation)
        self.assertIn('association, not a cause', explanation)

    def test_determinism_including_input_order_and_generator_seed(self):
        self.assertEqual(generate(), generate())
        self.assertNotEqual(generate(seed=1), generate(seed=2))
        self.assertEqual(model.train(list(reversed(self.rows))), self.fitted)
        self.assertEqual(model.score(self.fitted, self.rows), model.score(self.fitted, list(reversed(self.rows))))

    def test_calibration_partitions_exclude_each_outer_test_deck(self):
        partitions = []
        original = model._out_of_deck_logits
        def observe(rows):
            partitions.append(set(r['deck_id'] for r in rows))
            return original(rows)
        with mock.patch.object(model, '_out_of_deck_logits', side_effect=observe):
            model.train(self.rows)
        self.assertEqual(partitions, [{2, 3, 4}, {1, 3, 4}, {1, 2, 4}, {1, 2, 3}, {1, 2, 3, 4}])

    def test_flags_are_not_predictors_and_scores_are_bounded(self):
        altered = copy.deepcopy(self.rows)
        for row in altered:
            row.update(label=1, label_reasons=['delete'])
        before, after = model.score(self.fitted, self.rows), model.score(self.fitted, altered)
        self.assertEqual(before, after)
        problem = [r['quality_score'] for r, source in zip(before, self.rows) if source['label'] == 1]
        liked = [r['quality_score'] for r, source in zip(before, self.rows) if source['label'] == 0]
        self.assertLess(max(problem), min(liked))
        self.assertAlmostEqual(sum(1-r['quality_score'] for r in before)/len(before), 0.25, delta=0.1)
        for row in before:
            self.assertEqual(set(row), {'card_id', 'quality_score', 'forget_score', 'top_reasons'})
            self.assertTrue(0 <= row['quality_score'] <= 1)
            self.assertTrue(0 <= row['forget_score'] <= 1)

    def test_sparse_and_single_class_training_is_refused(self):
        for rows in ([], self.rows[:16], [r for r in self.rows if r['label'] == 0]):
            with self.assertRaises(features.QualityError):
                model.train(rows)

    def test_invalid_model_contracts_are_refused_without_echoing_metadata(self):
        for field, value in (('weights', [math.nan]*22), ('scales', [0]*22), ('feature_names', [SENTINEL]), ('intercept', SENTINEL)):
            broken = copy.deepcopy(self.fitted)
            broken[field] = value
            with self.assertRaises(features.QualityError):
                model.validate_model(broken)
        modified = copy.deepcopy(self.fitted)
        modified['untrusted_metadata'] = SENTINEL
        self.assertNotIn(SENTINEL, ' '.join(model.explain(modified)))
        modified['calibration']['slope'] = 0
        self.assertEqual(model.explain(modified), ['No shared liked-card traits were learned.'])


class CliPrivacyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as temp:
            cls.fitted = model.train(load_fixture(Path(temp)))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'input.json'
        self.payload = generate(cards_per_deck=16)
        for note in self.payload['notes']:
            note.update(front=note['front'] + SENTINEL, article=SENTINEL)
        self.source.write_text(json.dumps(self.payload))
        self.model_path = self.root / 'model.json'
        self.model_path.write_text(json.dumps(self.fitted))

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(socket, 'socket', side_effect=AssertionError('network is forbidden')):
            result = cli.main([str(arg) for arg in args])
        self.assertNotIn(SENTINEL, out.getvalue() + err.getvalue())
        return result, out.getvalue(), err.getvalue()

    def test_train_score_json_csv_and_explain_never_output_content(self):
        trained = self.root / 'trained.json'
        result, out, err = self.run_cli('train', '--input', self.source, '--synthetic', '--out', trained)
        self.assertEqual(result, 0, err)
        self.assertNotIn(SENTINEL, trained.read_text())
        self.assertNotIn('synthetic-1', trained.read_text())
        for extension in ('json', 'csv'):
            output = self.root / ('scores.' + extension)
            result, out, err = self.run_cli('score', '--input', self.source, '--synthetic', '--model', trained, '--out', output)
            self.assertEqual(result, 0, err)
            self.assertNotIn(SENTINEL, output.read_text())
            self.assertNotIn('synthetic-1', output.read_text())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        explained = self.root / 'explain.txt'
        self.assertEqual(self.run_cli('explain', '--model', trained, '--out', explained)[0], 0)
        self.assertNotIn(SENTINEL, explained.read_text())
        self.assertEqual(self.run_cli('explain', '--model', trained)[0], 0)

    def test_real_data_opt_in_is_offline_and_does_not_change_source(self):
        self.payload.pop('synthetic')
        self.source.write_text(json.dumps(self.payload))
        before = self.source.read_bytes()
        output = self.root / 'scores.json'
        self.assertEqual(self.run_cli('score', '--input', self.source, '--synthetic', '--model', self.model_path, '--out', output)[0], 2)
        self.assertFalse(output.exists())
        result, _, err = self.run_cli('score', '--input', self.source, '--real-data', '--model', self.model_path, '--out', output)
        self.assertEqual(result, 0, err)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertNotIn(SENTINEL, output.read_text())

    def test_failures_do_not_echo_bad_values_paths_or_source(self):
        bad = self.root / (SENTINEL + '.json')
        for value in ('{'+SENTINEL, json.dumps({**self.payload, 'cards': [{'id': SENTINEL}]})):
            bad.write_text(value)
            result, out, err = self.run_cli('train', '--input', bad, '--synthetic', '--out', self.root / 'unused.json')
            self.assertEqual(result, 2)
        self.assertFalse((self.root / 'unused.json').exists())

    def test_private_directory_modes_and_symlinks(self):
        public = self.root / 'public'
        public.mkdir(mode=0o755)
        public.chmod(0o755)
        with self.assertRaises(features.QualityError):
            cli.private_write(public / 'out.json', '{}')
        private = self.root / 'new-private'
        cli.private_write(private / 'out.json', '{}')
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
        link = self.root / 'link'
        link.symlink_to(private, target_is_directory=True)
        with self.assertRaises(features.QualityError):
            cli.private_write(link / 'out.json', '{}')
        file_link = private / 'link.json'
        file_link.symlink_to(private / 'out.json')
        with self.assertRaises(features.QualityError):
            cli.private_write(file_link, '{}')

    def test_refuses_overwriting_inputs_and_unknown_output_format(self):
        original = self.source.read_bytes()
        for output in (self.source, self.model_path, self.root / 'scores.txt'):
            self.assertEqual(self.run_cli('score', '--input', self.source, '--synthetic', '--model', self.model_path, '--out', output)[0], 2)
        self.assertEqual(self.source.read_bytes(), original)

    def test_synthetic_cli_and_optional_private_garden_map(self):
        output = self.root / 'synthetic.json'
        self.assertEqual(self.run_cli('synthetic', '--out', output, '--seed', 17)[0], 0)
        self.assertEqual(json.loads(output.read_text()), generate())
        db = self.root / 'collection.anki2'
        con = sqlite3.connect(db)
        con.execute('CREATE TABLE notes (id, guid, flds)')
        con.executemany('INSERT INTO notes VALUES (?,?,?)',
                       [(1000+i, n['guid'], n['front']+'\x1f'+n['back']) for i, n in enumerate(self.payload['notes'])])
        con.commit()
        con.close()
        mapping = self.root / 'map.json'
        result, _, err = self.run_cli('score', '--input', self.source, '--real-data', '--anki-db', db,
            '--model', self.model_path, '--out', self.root / 'scores.json', '--garden-map-out', mapping)
        self.assertEqual(result, 0, err)
        self.assertEqual(json.loads(mapping.read_text())[0], {'card_id': 1, 'nid': 1000})
        self.assertNotIn(SENTINEL, mapping.read_text())
        self.assertEqual(self.run_cli('score', '--input', self.source, '--synthetic', '--model', self.model_path,
            '--out', self.root / 'other.json', '--garden-map-out', mapping)[0], 2)


if __name__ == '__main__':
    unittest.main()

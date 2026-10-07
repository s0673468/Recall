"""Queue contract tests, not Android execution or device acceptance."""

import json
from pathlib import Path
import stat
import tempfile
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from android_acceptance_matrix import initialize, matrix


class MatrixTests(unittest.TestCase):
    def test_full_cartesian_contract_starts_without_evidence(self):
        rows = list(matrix())
        axes = ('flow', 'profile', 'theme', 'font_scale', 'talkback', 'locale')
        self.assertEqual(len(rows), 2592)
        self.assertEqual(len({tuple(row[k] for k in axes) for row in rows}), 2592)
        self.assertEqual(len({row['id'] for row in rows}), 2592)
        self.assertEqual(rows, list(matrix()))
        for row in rows:
            self.assertEqual(row['status'], 'pending')
            self.assertEqual(row['evidence'], [])
            self.assertIsNone(row['independent_verification'])

    def test_private_output_unknown_usage_and_existing_state_preservation(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'matrix'
            kwargs = dict(root_thread_id='synthetic', source_sha='a' * 40,
                          source_host='synthetic-host')
            initialize(destination, **kwargs)
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
            before = {p.name: p.read_bytes() for p in destination.iterdir()}
            for p in destination.iterdir():
                self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
            self.assertIsNone(json.loads(before['USAGE.json'])['total_tokens'])
            self.assertEqual(len(before['QUEUE.jsonl'].splitlines()), 2592)
            with self.assertRaises(FileExistsError):
                initialize(destination, **kwargs)
            self.assertEqual(before, {p.name: p.read_bytes() for p in destination.iterdir()})


if __name__ == '__main__':
    unittest.main()

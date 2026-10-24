import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import flag_report as report


class LikeReportTest(unittest.TestCase):
    def test_like_is_accepted_and_reported_separately(self):
        self.assertIn('like', report.FLAG_REASONS)
        parsed = report._parse_flag_rows([dict(guid='synthetic', reason='like', flagged_at='2026-10-01T00:00:00Z')])
        guid, reason, at = parsed[0]
        records = [report.FlagRecord(guid, reason, at, 1, 'Synthetic question?', 'Synthetic deck'),
                   report.FlagRecord('other', 'dislike', at, 1, 'Other question?', 'Synthetic deck')]
        text = report.render_markdown(records)
        self.assertIn('## Liked (keep this style) (1)', text)
        self.assertIn('## dislike (1)', text)
        self.assertGreater(text.index('## Liked'), text.index('## dislike'))

    def test_report_fetches_only_open_preferences(self):
        with mock.patch.object(report, '_request', return_value=[]) as request:
            self.assertEqual(report.fetch_flags('fixture', 'fixture'), [])
        self.assertEqual(request.call_args.kwargs['params']['status'], 'eq.open')

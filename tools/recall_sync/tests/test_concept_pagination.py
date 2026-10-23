"""Synthetic PostgREST pages with server caps below the requested limit."""

import json
import sys
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sync_concept_nodes as sync


class ConceptPaginationTests(unittest.TestCase):
    def test_short_pages_continue_until_an_empty_response(self):
        expected = [
            {"node_id": f"synthetic-{index}", "title": "Synthetic"}
            for index in range(7)
        ]
        for caps in ([2, 1, 3, 1], [1] * 7):
            with self.subTest(caps=caps):
                offsets = []

                def respond(request, **kwargs):
                    self.assertEqual(request.method, "GET")
                    query = urllib.parse.parse_qs(
                        urllib.parse.urlparse(request.full_url).query
                    )
                    self.assertEqual(query["order"], ["node_id.asc"])
                    self.assertEqual(query["limit"], [str(sync.PAGE_SIZE)])
                    offset = int(query["offset"][0])
                    cap = caps[len(offsets)] if len(offsets) < len(caps) else 1
                    offsets.append(offset)
                    response = mock.MagicMock()
                    response.__enter__.return_value.read.return_value = (
                        json.dumps(expected[offset:offset + cap]).encode()
                    )
                    return response

                with mock.patch.object(
                    sync.urllib.request, "urlopen", side_effect=respond
                ):
                    actual = sync._fetch_existing_rows("https://example.invalid", "")

                self.assertEqual(actual, {row["node_id"]: row for row in expected})
                self.assertEqual(offsets, [sum(caps[:i]) for i in range(len(caps) + 1)])

    def test_empty_first_page_finishes_without_another_request(self):
        with mock.patch.object(sync, "_request", return_value=[]) as request:
            self.assertEqual(sync._fetch_existing_rows("https://example.invalid", ""), {})
        request.assert_called_once()

    def test_duplicate_on_later_capped_page_still_fails_closed(self):
        row = {"node_id": "synthetic-duplicate"}
        with mock.patch.object(sync, "_request", side_effect=[[row], [row]]):
            with self.assertRaisesRegex(RuntimeError, "duplicate cloud concept node id"):
                sync._fetch_existing_rows("https://example.invalid", "")


if __name__ == "__main__":
    unittest.main()

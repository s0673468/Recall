from __future__ import annotations

import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock
import urllib.parse


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import flag_report as report


FIXED_FLAGS = [
    {
        "card_id": 4,
        "guid": "g-duplicate",
        "reason": "duplicate",
        "flagged_at": "2026-08-03T10:00:00-03:00",
        "device": "private-device",
        "client_event_id": "private-event",
    },
    {
        "card_id": 2,
        "guid": "g-confusing",
        "reason": "confusing",
        "flagged_at": "2026-08-02T12:00:00Z",
        "user_id": "private-user",
    },
    {
        "card_id": 1,
        "guid": "g-wrong",
        "reason": "wrong",
        "flagged_at": "2026-08-01T08:00:00Z",
    },
    {
        "card_id": 3,
        "guid": "g-too-long",
        "reason": "too_long",
        "flagged_at": "2026-08-01T09:00:00Z",
    },
    {
        "card_id": 5,
        "guid": "g-wrong",
        "reason": "wrong",
        "flagged_at": "2026-08-02T08:00:00Z",
    },
]

FIXED_NOTES = [
    {"guid": "g-confusing", "front": "<p>Confusing front</p>", "deck_id": 10},
    {"guid": "g-duplicate", "front": "Duplicate front", "deck_id": 20},
    {"guid": "g-too-long", "front": "Too long front", "deck_id": 10},
    {"guid": "g-wrong", "front": "Wrong front", "deck_id": 10},
]

FIXED_DECKS = [
    {"deck_id": 10, "name": "Portuguese"},
    {"deck_id": 20, "name": "Private deck"},
]


class SafeFrontTests(unittest.TestCase):
    def test_strips_markup_hidden_content_and_bounds_the_prefix(self) -> None:
        front = (
            "<p>Visible <b>prompt</b> | </p>"
            "<script>private-api-key=should-not-appear</script>"
            "<style>.private { display: none }</style>"
            + ("tail " * 100)
        )
        value = report.safe_front_prefix(front, limit=24)

        self.assertEqual(value, "Visible prompt | tail t…")
        self.assertNotIn("private-api-key", value)
        self.assertLessEqual(len(value), 24)

    def test_empty_front_has_a_safe_placeholder(self) -> None:
        self.assertEqual(report.safe_front_prefix("<p></p>"), "[empty front]")


class RenderTests(unittest.TestCase):
    def test_groups_live_reasons_and_preserves_duplicate_flags(self) -> None:
        records = [
            report.FlagRecord(
                guid="g-wrong-2",
                reason="wrong",
                flagged_at=report._parse_timestamp("2026-08-02T08:00:00Z"),
                deck_id=10,
                front="Wrong second",
                deck_name="Portuguese",
            ),
            report.FlagRecord(
                guid="g-wrong-1",
                reason="wrong",
                flagged_at=report._parse_timestamp("2026-08-01T08:00:00Z"),
                deck_id=10,
                front="Wrong first",
                deck_name="Portuguese",
            ),
            report.FlagRecord(
                guid="g-wrong-1",
                reason="wrong",
                flagged_at=report._parse_timestamp("2026-08-01T08:00:00Z"),
                deck_id=10,
                front="Wrong first",
                deck_name="Portuguese",
            ),
            report.FlagRecord(
                guid="g-too-long",
                reason="too_long",
                flagged_at=report._parse_timestamp("2026-08-03T08:00:00Z"),
                deck_id=10,
                front="Long front",
                deck_name="Portuguese",
            ),
        ]

        output = report.render_markdown(records)

        self.assertLess(output.index("## wrong (3)"), output.index("## too_long (1)"))
        self.assertEqual(output.count("g-wrong-1"), 2)
        self.assertIn("| <code>g-wrong-1</code> |", output)
        self.assertIn("| <code>2026-08-01</code> |", output)
        self.assertNotIn("card_id", output)
        self.assertNotIn("private-device", output)
        self.assertNotIn("private-event", output)

    def test_markdown_cells_escape_markup_and_pipes(self) -> None:
        record = report.FlagRecord(
            guid="g|1",
            reason="wrong",
            flagged_at=report._parse_timestamp("2026-08-01T00:00:00Z"),
            deck_id=1,
            front="&lt;secret&gt; | `literal`",
            deck_name="Deck | one",
        )

        output = report.render_markdown([record])

        self.assertIn("<code>g&#124;1</code>", output)
        self.assertIn("<code>&lt;secret&gt; &#124; `literal`</code>", output)
        self.assertIn("<code>Deck &#124; one</code>", output)


class CollectionTests(unittest.TestCase):
    def request_fixture(self, calls: list[tuple[str, dict[str, str]]]):
        def request(
            url: str,
            key: str,
            *,
            table: str,
            params: dict[str, str],
        ) -> list[dict[str, object]]:
            calls.append((table, dict(params)))
            if table == "note_flags" and params.get("limit") == "0":
                return []
            if table == "notes" and params.get("limit") == "0":
                return []
            if table == "decks" and params.get("limit") == "0":
                return []
            if table == "note_flags":
                return FIXED_FLAGS
            if table == "notes":
                return FIXED_NOTES
            if table == "decks":
                return FIXED_DECKS
            raise AssertionError(table)

        return request

    def test_collects_only_required_context_after_schema_preflight(self) -> None:
        calls: list[tuple[str, dict[str, str]]] = []
        with mock.patch.object(report, "_request", side_effect=self.request_fixture(calls)):
            records = report.collect_records("https://example.invalid", "service-key")

        self.assertEqual([table for table, _ in calls[:3]], ["note_flags", "notes", "decks"])
        self.assertEqual(calls[0][1], {"select": "card_id,guid,reason,flagged_at", "limit": "0"})
        self.assertEqual(calls[1][1], {"select": "guid,front,deck_id", "limit": "0"})
        self.assertEqual(calls[2][1], {"select": "deck_id,name", "limit": "0"})
        self.assertEqual([record.reason for record in records], [
            "wrong", "wrong", "confusing", "too_long", "duplicate",
        ])
        self.assertEqual([record.guid for record in records[:2]], ["g-wrong", "g-wrong"])
        self.assertTrue(all(table in {"note_flags", "notes", "decks"} for table, _ in calls))
        output = report.render_markdown(records)
        for reason in report.FLAG_REASONS:
            self.assertIn(f"## {reason}", output)
        self.assertNotIn("private-user", output)
        self.assertNotIn("client_event_id", output)

    def test_unknown_reason_fails_closed_before_context_fetch(self) -> None:
        calls: list[tuple[str, dict[str, str]]] = []

        def request(*args, **kwargs):
            table = kwargs["table"]
            params = kwargs["params"]
            calls.append((table, dict(params)))
            if params.get("limit") == "0":
                return []
            return [{**FIXED_FLAGS[0], "reason": "incorrect"}]

        with mock.patch.object(report, "_request", side_effect=request):
            with self.assertRaisesRegex(report.DataContractError, "fixed live set"):
                report.collect_records("https://example.invalid", "service-key")

        self.assertEqual([table for table, _ in calls], ["note_flags", "notes", "decks", "note_flags"])

    def test_missing_context_fails_closed_without_rendering(self) -> None:
        calls: list[tuple[str, dict[str, str]]] = []
        fixture = self.request_fixture(calls)

        def missing_note(*args, **kwargs):
            if kwargs["table"] == "notes" and kwargs["params"].get("limit") != "0":
                return []
            return fixture(*args, **kwargs)

        with mock.patch.object(report, "_request", side_effect=missing_note):
            with self.assertRaisesRegex(report.DataContractError, "missing note context"):
                report.collect_records("https://example.invalid", "service-key")


class PreflightTests(unittest.TestCase):
    def test_schema_failure_does_not_include_response_body(self) -> None:
        secret_response = "service-key and private card front"
        with mock.patch.object(
            report,
            "_request",
            side_effect=report.SupabaseRequestError("note_flags", 404),
        ):
            with self.assertRaisesRegex(report.SchemaPreflightError, "no report was written") as raised:
                report.preflight_schema("https://example.invalid", "service-key")

        self.assertNotIn(secret_response, str(raised.exception))

    def test_request_is_get_only_and_does_not_send_a_body(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b"[]"
        with mock.patch.object(report.urllib.request, "urlopen", return_value=response) as urlopen:
            report._request(
                "https://example.invalid",
                "service-key",
                table="note_flags",
                params={"select": "guid", "limit": "0"},
            )

        request = urlopen.call_args.args[0]
        self.assertEqual(request.method, "GET")
        self.assertIsNone(request.data)
        self.assertNotIn("Prefer", request.headers)
        self.assertEqual(
            urllib.parse.parse_qs(urllib.parse.urlparse(request.full_url).query),
            {"select": ["guid"], "limit": ["0"]},
        )


class MainTests(unittest.TestCase):
    def test_dry_run_makes_no_cloud_request(self) -> None:
        stdout = io.StringIO()
        with mock.patch.object(report, "_request") as request, contextlib.redirect_stdout(stdout):
            result = report.main(["--dry-run"])

        self.assertEqual(result, 0)
        request.assert_not_called()
        self.assertIn("note_flags: card_id, guid, reason, flagged_at", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()

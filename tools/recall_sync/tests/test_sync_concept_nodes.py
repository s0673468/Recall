from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import sync_concept_nodes as sync


def cloud_row(
    node_id: str,
    title: str,
    module: str,
    difficulty: int | None,
    updated_at: str,
) -> dict[str, object]:
    return {
        "node_id": node_id,
        "title": title,
        "module": module,
        "difficulty": difficulty,
        "updated_at": updated_at,
    }


class ParseNodesTests(unittest.TestCase):
    def parse_source(self, source: str) -> list[dict[str, object]]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "concepts.yaml"
            path.write_text(source, encoding="utf-8")
            return sync.parse_nodes(path)

    def test_rejects_empty_nodes(self) -> None:
        with self.assertRaisesRegex(ValueError, "non-empty nodes list"):
            self.parse_source("nodes: []\n")

    def test_rejects_missing_node_id(self) -> None:
        with self.assertRaisesRegex(ValueError, "node 0 has no id"):
            self.parse_source("nodes:\n  - title: Missing\n")

    def test_rejects_duplicate_node_ids_before_sync(self) -> None:
        source = """
nodes:
  - id: m00-example
    title: First
  - id: m00-example
    title: Duplicate
"""
        with self.assertRaisesRegex(
            ValueError,
            "duplicate concept node id 'm00-example'",
        ):
            self.parse_source(source)


class AdditiveSyncTests(unittest.TestCase):
    metis_rows = [
        {
            "node_id": "m00-owned",
            "title": "Owned",
            "module": "M00",
            "difficulty": 2,
        }
    ]
    unmanaged_rows = {
        "ml-primer-local": cloud_row(
            "ml-primer-local",
            "Primer",
            "ML",
            3,
            "2026-07-29T00:00:00Z",
        ),
        "pt-deck-local": cloud_row(
            "pt-deck-local",
            "Portuguese",
            "PT",
            1,
            "2026-07-29T00:00:00Z",
        ),
    }

    def owned_cloud_row(self, updated_at: str) -> dict[str, object]:
        return cloud_row(
            "m00-owned",
            "Owned",
            "M00",
            2,
            updated_at,
        )

    def test_preserves_all_132_cloud_only_rows_and_never_deletes(
        self,
    ) -> None:
        managed = [
            {
                "node_id": f"m{index:02d}-owned",
                "title": f"Owned {index}",
                "module": f"M{index:02d}",
                "difficulty": index % 5,
            }
            for index in range(103)
        ]
        managed_before = {
            str(row["node_id"]): {
                **row,
                "updated_at": "before",
            }
            for row in managed
        }
        managed_after = {
            str(row["node_id"]): {
                **row,
                "updated_at": "after",
            }
            for row in managed
        }
        unmanaged = {
            f"primer-local-{index:03d}": cloud_row(
                f"primer-local-{index:03d}",
                f"Primer {index}",
                "Primer",
                index % 5,
                "unchanged",
            )
            for index in range(132)
        }
        before = {
            **managed_before,
            **unmanaged,
        }
        after = {
            **managed_after,
            **unmanaged,
        }
        calls: list[dict[str, object]] = []

        def record_request(*args, **kwargs):
            calls.append(kwargs)
            return list(managed_after.values())

        output = io.StringIO()
        with (
            mock.patch.object(
                sync,
                "parse_nodes",
                return_value=managed,
            ),
            mock.patch.object(sync, "_request", side_effect=record_request),
            mock.patch.object(
                sync,
                "_fetch_existing_rows",
                side_effect=[before, after],
            ),
            redirect_stdout(output),
        ):
            result = sync.run("https://example.invalid", "secret")

        self.assertEqual(
            result,
            {
                "upserted": 103,
                "preserved_unmanaged": 132,
                "cloud_total": 235,
            },
        )
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["method"], "POST")
        self.assertEqual(calls[0]["params"], {"on_conflict": "node_id"})
        self.assertEqual(calls[0]["body"], managed)
        self.assertNotIn("DELETE", [call["method"] for call in calls])
        self.assertIn("preserved_unmanaged=132", output.getvalue())

    def test_fails_when_upsert_response_is_short(self) -> None:
        with (
            mock.patch.object(
                sync,
                "parse_nodes",
                return_value=self.metis_rows,
            ),
            mock.patch.object(sync, "_fetch_existing_rows", return_value={}),
            mock.patch.object(sync, "_request", return_value=[]),
        ):
            with self.assertRaisesRegex(
                RuntimeError,
                "returned 0 rows, expected 1",
            ):
                sync.run("https://example.invalid", "secret")

    def test_fails_when_upsert_response_has_wrong_fields(self) -> None:
        wrong = {
            **self.owned_cloud_row("after"),
            "title": "Wrong",
        }
        with (
            mock.patch.object(
                sync,
                "parse_nodes",
                return_value=self.metis_rows,
            ),
            mock.patch.object(sync, "_fetch_existing_rows", return_value={}),
            mock.patch.object(sync, "_request", return_value=[wrong]),
        ):
            with self.assertRaisesRegex(
                RuntimeError,
                "upsert response mismatch",
            ):
                sync.run("https://example.invalid", "secret")

    def test_fails_when_an_unmanaged_row_changes(self) -> None:
        before = {
            "m00-owned": self.owned_cloud_row("before"),
            **self.unmanaged_rows,
        }
        changed_unmanaged = dict(self.unmanaged_rows)
        changed_unmanaged["ml-primer-local"] = {
            **changed_unmanaged["ml-primer-local"],
            "title": "Unexpected change",
        }
        after = {
            "m00-owned": self.owned_cloud_row("after"),
            **changed_unmanaged,
        }
        with (
            mock.patch.object(
                sync,
                "parse_nodes",
                return_value=self.metis_rows,
            ),
            mock.patch.object(
                sync,
                "_fetch_existing_rows",
                side_effect=[before, after],
            ),
            mock.patch.object(
                sync,
                "_request",
                return_value=[self.owned_cloud_row("after")],
            ),
        ):
            with self.assertRaisesRegex(
                RuntimeError,
                "unmanaged concept rows changed",
            ):
                sync.run("https://example.invalid", "secret")

    def test_two_runs_are_idempotent(self) -> None:
        stable = {
            "m00-owned": self.owned_cloud_row("same"),
            **self.unmanaged_rows,
        }
        with (
            mock.patch.object(
                sync,
                "parse_nodes",
                return_value=self.metis_rows,
            ),
            mock.patch.object(
                sync,
                "_fetch_existing_rows",
                side_effect=[stable, stable, stable, stable],
            ),
            mock.patch.object(
                sync,
                "_request",
                side_effect=[
                    [self.owned_cloud_row("same")],
                    [self.owned_cloud_row("same")],
                ],
            ),
        ):
            first = sync.run("https://example.invalid", "secret")
            second = sync.run("https://example.invalid", "secret")
        self.assertEqual(first, second)


class RequestTests(unittest.TestCase):
    def test_upsert_uses_explicit_conflict_target_and_representation(
        self,
    ) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b"[]"
        with mock.patch.object(
            sync.urllib.request,
            "urlopen",
            return_value=response,
        ) as urlopen:
            sync._request(
                "https://example.invalid",
                "secret",
                method="POST",
                table="concept_nodes",
                params={"on_conflict": "node_id"},
                body=[{"node_id": "m00-owned"}],
            )

        request = urlopen.call_args.args[0]
        query = urllib.parse.parse_qs(
            urllib.parse.urlparse(request.full_url).query
        )
        self.assertEqual(query["on_conflict"], ["node_id"])
        self.assertEqual(
            request.get_header("Prefer"),
            "resolution=merge-duplicates,return=representation",
        )
        self.assertEqual(json.loads(request.data), [{"node_id": "m00-owned"}])

    def test_http_409_propagates_as_failure(self) -> None:
        conflict = urllib.error.HTTPError(
            "https://example.invalid/rest/v1/concept_nodes",
            409,
            "Conflict",
            {},
            None,
        )
        try:
            with mock.patch.object(
                sync.urllib.request,
                "urlopen",
                side_effect=conflict,
            ):
                with self.assertRaises(urllib.error.HTTPError):
                    sync._request(
                        "https://example.invalid",
                        "secret",
                        method="POST",
                        table="concept_nodes",
                        params={"on_conflict": "node_id"},
                        body=[{"node_id": "m00-owned"}],
                    )
        finally:
            conflict.close()

    def test_pagination_is_stably_ordered_past_one_thousand_rows(
        self,
    ) -> None:
        first_page = [
            cloud_row(f"node-{index:04d}", "Title", "M", 1, "same")
            for index in range(1000)
        ]
        second_page = [
            cloud_row("node-1000", "Title", "M", 1, "same")
        ]
        with mock.patch.object(
            sync,
            "_request",
            side_effect=[first_page, second_page],
        ) as request:
            rows = sync._fetch_existing_rows(
                "https://example.invalid",
                "secret",
            )

        self.assertEqual(len(rows), 1001)
        calls = request.call_args_list
        self.assertEqual(
            calls[0].kwargs["params"],
            {
                "select": "node_id,title,module,difficulty,updated_at",
                "order": "node_id.asc",
                "limit": "1000",
                "offset": "0",
            },
        )
        self.assertEqual(calls[1].kwargs["params"]["offset"], "1000")


if __name__ == "__main__":
    unittest.main()

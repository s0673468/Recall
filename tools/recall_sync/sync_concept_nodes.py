#!/usr/bin/env python3
"""Additively sync METIS concept rows into Recall's shared concept table.

``concept_nodes`` contains more than the METIS graph. Primer authoring and
deck-local mapping also create valid rows there, so this job owns only the
METIS rows it upserts. It must never infer deletion authority from absence in
``concepts.yaml``.

Env:
  SUPABASE_URL          https://<ref>.supabase.co
  SUPABASE_SERVICE_KEY  service-role key

Dry run (no network):
  python sync_concept_nodes.py --dry-run
"""

from __future__ import annotations

import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import yaml


CONCEPTS_YAML = Path(
    os.environ.get(
        "METIS_CONCEPTS_YAML",
        Path.home() / "Code/METIS/graph/concepts.yaml",
    )
)
HTTP_TIMEOUT_SECONDS = 30
PAGE_SIZE = 1000


def parse_nodes(path: Path = CONCEPTS_YAML) -> list[dict[str, object]]:
    """Read concepts.yaml and fail closed on missing or duplicate IDs."""
    with path.open("r", encoding="utf-8") as handle:
        graph = yaml.safe_load(handle)
    if not isinstance(graph, dict):
        raise ValueError(f"{path}: expected a mapping at the top level")

    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    nodes = graph.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError(f"{path}: expected a non-empty nodes list")
    for index, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise ValueError(f"{path}: node {index} is not a mapping")
        node_id = node.get("id")
        if not node_id:
            raise ValueError(f"{path}: node {index} has no id")
        node_id = str(node_id)
        if node_id in seen:
            raise ValueError(f"{path}: duplicate concept node id {node_id!r}")
        seen.add(node_id)
        difficulty = node.get("difficulty")
        rows.append(
            {
                "node_id": node_id,
                "title": node.get("title") or node_id,
                "module": node.get("module") or "",
                "difficulty": (
                    int(difficulty) if difficulty is not None else None
                ),
            }
        )
    return rows


def _request(
    url: str,
    key: str,
    *,
    method: str,
    table: str,
    params: dict[str, str] | None = None,
    body: list[dict[str, object]] | None = None,
) -> list[dict[str, object]]:
    """Issue one PostgREST request and return its JSON response."""
    endpoint = f"{url}/rest/v1/{table}"
    if params:
        endpoint = f"{endpoint}?{urllib.parse.urlencode(params)}"
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Prefer"] = "resolution=merge-duplicates,return=representation"
    request = urllib.request.Request(
        endpoint,
        data=data,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(
        request,
        timeout=HTTP_TIMEOUT_SECONDS,
    ) as response:
        raw = response.read()
    return json.loads(raw) if raw else []


def _fetch_existing_rows(
    url: str,
    key: str,
) -> dict[str, dict[str, object]]:
    """Fetch every cloud row in stable order and reject duplicate IDs."""
    rows: dict[str, dict[str, object]] = {}
    offset = 0
    while True:
        page = _request(
            url,
            key,
            method="GET",
            table="concept_nodes",
            params={
                "select": "node_id,title,module,difficulty,updated_at",
                "order": "node_id.asc",
                "limit": str(PAGE_SIZE),
                "offset": str(offset),
            },
        )
        for row in page:
            node_id = str(row["node_id"])
            if node_id in rows:
                raise RuntimeError(
                    f"duplicate cloud concept node id {node_id!r}"
                )
            rows[node_id] = row
        if len(page) < PAGE_SIZE:
            return rows
        offset += PAGE_SIZE


def run(url: str, key: str) -> dict[str, int]:
    """Upsert owned rows and prove every unmanaged row stayed unchanged."""
    rows = parse_nodes()
    metis_ids = {str(row["node_id"]) for row in rows}
    before = _fetch_existing_rows(url, key)
    unmanaged_before = {
        node_id: row
        for node_id, row in before.items()
        if node_id not in metis_ids
    }

    returned = _request(
        url,
        key,
        method="POST",
        table="concept_nodes",
        params={"on_conflict": "node_id"},
        body=rows,
    )
    if len(returned) != len(rows):
        raise RuntimeError(
            "concept-node upsert returned "
            f"{len(returned)} rows, expected {len(rows)}"
        )

    expected_by_id = {str(row["node_id"]): row for row in rows}
    returned_by_id = {str(row.get("node_id")): row for row in returned}
    if set(returned_by_id) != metis_ids:
        raise RuntimeError("concept-node upsert returned the wrong node IDs")
    for node_id, expected in expected_by_id.items():
        actual = returned_by_id[node_id]
        if any(actual.get(field) != expected[field] for field in expected):
            raise RuntimeError(
                f"concept-node upsert response mismatch for {node_id!r}"
            )

    after = _fetch_existing_rows(url, key)
    unmanaged_after = {
        node_id: row
        for node_id, row in after.items()
        if node_id not in metis_ids
    }
    if unmanaged_after != unmanaged_before:
        raise RuntimeError("unmanaged concept rows changed during METIS sync")
    for node_id, expected in expected_by_id.items():
        actual = after.get(node_id)
        if actual is None or any(
            actual.get(field) != expected[field] for field in expected
        ):
            raise RuntimeError(
                f"concept-node readback mismatch for {node_id!r}"
            )

    preserved_unmanaged = len(unmanaged_after)
    result = {
        "upserted": len(rows),
        "preserved_unmanaged": preserved_unmanaged,
        "cloud_total": len(after),
    }
    print(
        "concept_nodes: "
        f"upserted={result['upserted']} "
        f"preserved_unmanaged={result['preserved_unmanaged']} "
        f"cloud_total={result['cloud_total']}"
    )
    return result


def dry_run() -> None:
    """Parse the graph and report counts without touching the network."""
    rows = parse_nodes()
    modules = sorted({str(row["module"]) for row in rows})
    print(f"nodes={len(rows)} modules={len(modules)}")
    if rows:
        print("sample:", json.dumps(rows[0], ensure_ascii=False))


def main() -> int:
    if "--dry-run" in sys.argv:
        dry_run()
        return 0

    try:
        from dotenv import load_dotenv

        load_dotenv(Path(__file__).resolve().parent / ".env")
    except ImportError:
        pass
    supabase_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not supabase_url or not service_key:
        raise SystemExit(
            "SUPABASE_URL / SUPABASE_SERVICE_KEY missing — check the runtime .env"
        )
    run(supabase_url.rstrip("/"), service_key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Render a local, read-only authoring queue from Recall note flags.

The report intentionally reads only the flag rows and the note/deck context
needed to author a correction. It never exposes the service key or the rest of
the flag payload, and this module has no PostgREST write path.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Iterable, Mapping, Sequence


FLAG_REASONS = ("wrong", "confusing", "too_long", "duplicate")
REQUIRED_SCHEMA = {
    "note_flags": ("card_id", "guid", "reason", "flagged_at"),
    "notes": ("guid", "front", "deck_id"),
    "decks": ("deck_id", "name"),
}
HTTP_TIMEOUT_SECONDS = 30
PAGE_SIZE = 1000
CONTEXT_BATCH_SIZE = 100
SAFE_FRONT_PREFIX_CHARS = 160


class FlagReportError(Exception):
    """A safe-to-display failure that contains no cloud response body."""


class SchemaPreflightError(FlagReportError):
    """The checked-in client contract could not be proven remotely."""


class DataContractError(FlagReportError):
    """Cloud rows do not satisfy the fixed report input contract."""


class SupabaseRequestError(FlagReportError):
    """A GET failed without retaining or exposing the response body."""

    def __init__(self, table: str, status: int | None = None) -> None:
        self.table = table
        self.status = status
        suffix = f" (HTTP {status})" if status is not None else ""
        super().__init__(f"read of {table} failed{suffix}")


@dataclass(frozen=True)
class FlagRecord:
    guid: str
    reason: str
    flagged_at: datetime
    deck_id: int
    front: str
    deck_name: str


class _VisibleTextParser(HTMLParser):
    """Extract bounded human-visible text without retaining script/style data."""

    _hidden_tags = frozenset({"script", "style", "noscript", "svg"})
    _spacing_tags = frozenset(
        {"address", "article", "aside", "blockquote", "br", "div", "li", "p", "pre", "section"}
    )

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._hidden_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in self._hidden_tags:
            self._hidden_depth += 1
        elif self._hidden_depth == 0 and tag in self._spacing_tags:
            self.parts.append(" ")

    def handle_startendtag(
        self,
        tag: str,
        attrs: list[tuple[str, str | None]],
    ) -> None:
        if self._hidden_depth == 0 and tag.lower() in self._spacing_tags:
            self.parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in self._hidden_tags and self._hidden_depth:
            self._hidden_depth -= 1
        elif self._hidden_depth == 0 and tag in self._spacing_tags:
            self.parts.append(" ")

    def handle_data(self, data: str) -> None:
        if self._hidden_depth == 0:
            self.parts.append(data)


def safe_front_prefix(front: str, limit: int = SAFE_FRONT_PREFIX_CHARS) -> str:
    """Return a bounded, plain-text prefix suitable for a local Markdown file."""
    if limit < 2:
        raise ValueError("front prefix limit must be at least 2")
    parser = _VisibleTextParser()
    parser.feed(front)
    parser.close()
    visible = " ".join("".join(parser.parts).split())
    if not visible:
        return "[empty front]"
    if len(visible) <= limit:
        return visible
    return f"{visible[: limit - 1]}…"


def _request(
    url: str,
    key: str,
    *,
    table: str,
    params: Mapping[str, str],
) -> list[dict[str, object]]:
    """Issue one GET-only PostgREST request and return object rows.

    Keeping the method fixed here is deliberate: the report tool cannot issue
    INSERT, UPDATE, UPSERT, or DELETE requests even if a caller supplies bad
    arguments.
    """
    endpoint = f"{url.rstrip('/')}/rest/v1/{table}"
    if params:
        endpoint = f"{endpoint}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(
        endpoint,
        headers={
            "Accept": "application/json",
            "apikey": key,
            "Authorization": f"Bearer {key}",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=HTTP_TIMEOUT_SECONDS,
        ) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raise SupabaseRequestError(table, error.code) from None
    except urllib.error.URLError:
        raise SupabaseRequestError(table) from None

    try:
        payload = json.loads(raw) if raw else []
    except json.JSONDecodeError:
        raise SupabaseRequestError(table) from None
    if not isinstance(payload, list) or any(not isinstance(row, dict) for row in payload):
        raise SupabaseRequestError(table)
    return [dict(row) for row in payload]


def preflight_schema(url: str, key: str) -> None:
    """Prove the read-only table projections before fetching any report data."""
    for table, columns in REQUIRED_SCHEMA.items():
        try:
            _request(
                url,
                key,
                table=table,
                params={"select": ",".join(columns), "limit": "0"},
            )
        except SupabaseRequestError as error:
            required = ", ".join(columns)
            raise SchemaPreflightError(
                f"schema preflight failed for {table}; required columns: {required}; "
                "no report was written",
            ) from error


def _parse_timestamp(value: object) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise DataContractError("flagged_at is missing or not text; no report was written")
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = f"{normalized[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        raise DataContractError(
            "flagged_at contains an invalid timestamp; no report was written",
        ) from None
    if parsed.tzinfo is None:
        raise DataContractError(
            "flagged_at must include a timezone offset; no report was written",
        )
    return parsed.astimezone(timezone.utc)


def _required_guid(row: Mapping[str, object]) -> str:
    guid = row.get("guid")
    if not isinstance(guid, str) or not guid.strip():
        raise DataContractError("a flag is missing its guid; no report was written")
    if any(ord(char) < 32 for char in guid):
        raise DataContractError("a flag guid contains control text; no report was written")
    return guid.strip()


def _parse_flag_rows(rows: Iterable[Mapping[str, object]]) -> list[tuple[str, str, datetime]]:
    parsed: list[tuple[str, str, datetime]] = []
    for row in rows:
        guid = _required_guid(row)
        reason = row.get("reason")
        if reason not in FLAG_REASONS:
            raise DataContractError(
                "note_flags contains a reason outside the fixed live set "
                "(wrong, confusing, too_long, duplicate); no report was written",
            )
        parsed.append((guid, str(reason), _parse_timestamp(row.get("flagged_at"))))
    return parsed


def fetch_flags(url: str, key: str) -> list[tuple[str, str, datetime]]:
    """Read all flags in a stable page order without exposing raw rows."""
    rows: list[dict[str, object]] = []
    offset = 0
    while True:
        page = _request(
            url,
            key,
            table="note_flags",
            params={
                "select": "card_id,guid,reason,flagged_at",
                "order": "flagged_at.asc,guid.asc",
                "limit": str(PAGE_SIZE),
                "offset": str(offset),
            },
        )
        rows.extend(page)
        if len(page) < PAGE_SIZE:
            break
        offset += PAGE_SIZE
    return _parse_flag_rows(rows)


def _postgrest_in(values: Sequence[str]) -> str:
    """Build a quoted PostgREST ``in`` value without accepting query syntax."""
    quoted: list[str] = []
    for value in values:
        if any(ord(char) < 32 for char in value):
            raise DataContractError("a guid contains control text; no report was written")
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        quoted.append(f'"{escaped}"')
    return f"in.({','.join(quoted)})"


def _as_deck_id(value: object) -> int:
    if isinstance(value, bool):
        raise DataContractError("a note has an invalid deck id; no report was written")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            pass
    raise DataContractError("a note has an invalid deck id; no report was written")


def fetch_context(
    url: str,
    key: str,
    guids: Iterable[str],
) -> tuple[dict[str, tuple[str, int]], dict[int, str]]:
    """Read only the flagged note fronts and the referenced deck names."""
    unique_guids = sorted(set(guids))
    notes: dict[str, tuple[str, int]] = {}
    for start in range(0, len(unique_guids), CONTEXT_BATCH_SIZE):
        batch = unique_guids[start : start + CONTEXT_BATCH_SIZE]
        if not batch:
            continue
        page = _request(
            url,
            key,
            table="notes",
            params={
                "select": "guid,front,deck_id",
                "guid": _postgrest_in(batch),
                "order": "guid.asc",
            },
        )
        for row in page:
            guid = _required_guid(row)
            if guid in notes:
                raise DataContractError("duplicate note context was returned; no report was written")
            front = row.get("front")
            if front is None:
                front = ""
            if not isinstance(front, str):
                raise DataContractError("a note front is not text; no report was written")
            notes[guid] = (front, _as_deck_id(row.get("deck_id")))

    deck_ids = sorted({deck_id for _, deck_id in notes.values()})
    decks: dict[int, str] = {}
    for start in range(0, len(deck_ids), CONTEXT_BATCH_SIZE):
        batch = deck_ids[start : start + CONTEXT_BATCH_SIZE]
        if not batch:
            continue
        page = _request(
            url,
            key,
            table="decks",
            params={
                "select": "deck_id,name",
                "deck_id": _postgrest_in([str(deck_id) for deck_id in batch]),
                "order": "deck_id.asc",
            },
        )
        for row in page:
            deck_id = _as_deck_id(row.get("deck_id"))
            if deck_id in decks:
                raise DataContractError("duplicate deck context was returned; no report was written")
            name = row.get("name")
            decks[deck_id] = name.strip() if isinstance(name, str) and name.strip() else "[unnamed deck]"
    return notes, decks


def collect_records(url: str, key: str) -> list[FlagRecord]:
    """Fetch and validate the complete report input before rendering."""
    preflight_schema(url, key)
    flags = fetch_flags(url, key)
    notes, decks = fetch_context(url, key, (guid for guid, _, _ in flags))

    missing_notes = sum(guid not in notes for guid, _, _ in flags)
    if missing_notes:
        raise DataContractError(
            f"{missing_notes} flag(s) reference missing note context; no report was written",
        )
    missing_decks = sum(
        note[1] not in decks for note in notes.values()
    )
    if missing_decks:
        raise DataContractError(
            f"{missing_decks} note(s) reference missing deck context; no report was written",
        )

    records = [
        FlagRecord(
            guid=guid,
            reason=reason,
            flagged_at=flagged_at,
            deck_id=notes[guid][1],
            front=notes[guid][0],
            deck_name=decks[notes[guid][1]],
        )
        for guid, reason, flagged_at in flags
    ]
    return sorted(
        records,
        key=lambda record: (
            FLAG_REASONS.index(record.reason),
            record.flagged_at,
            record.guid,
            record.deck_id,
        ),
    )


def _markdown_cell(value: str) -> str:
    escaped = html.escape(value, quote=False).replace("|", "&#124;")
    return f"<code>{escaped}</code>"


def render_markdown(records: Iterable[FlagRecord]) -> str:
    """Render a deterministic grouped queue with no generation timestamp."""
    grouped: dict[str, list[FlagRecord]] = defaultdict(list)
    for record in records:
        if record.reason not in FLAG_REASONS:
            raise DataContractError(
                "a report record has a reason outside the fixed live set; "
                "no report was written",
            )
        grouped[record.reason].append(record)

    lines = [
        "# Recall flag authoring queue",
        "",
        "> Read-only report. Flags and cards are not changed. Front values are "
        "bounded plain-text prefixes for local authoring context.",
        "",
    ]
    if not grouped:
        lines.extend(["No flags found.", ""])
        return "\n".join(lines)

    for reason in FLAG_REASONS:
        reason_records = grouped.get(reason, [])
        if not reason_records:
            continue
        lines.extend(
            [
                f"## {reason} ({len(reason_records)})",
                "",
                "| GUID | Front prefix | Deck | Date (UTC) |",
                "| --- | --- | --- | --- |",
            ]
        )
        for record in reason_records:
            lines.append(
                "| "
                + " | ".join(
                    (
                        _markdown_cell(record.guid),
                        _markdown_cell(safe_front_prefix(record.front)),
                        _markdown_cell(record.deck_name),
                        _markdown_cell(record.flagged_at.date().isoformat()),
                    )
                )
                + " |",
            )
        lines.append("")
    return "\n".join(lines)


def _load_local_env() -> None:
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    load_dotenv(Path(__file__).resolve().parent / ".env")


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Read note_flags and render a local Markdown authoring queue.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="write the completed report to this local path instead of stdout",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show the read-only schema contract without contacting Supabase",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    if args.dry_run:
        print("flag_report: dry-run; no Supabase request made")
        for table, columns in REQUIRED_SCHEMA.items():
            print(f"requires {table}: {', '.join(columns)}")
        return 0

    _load_local_env()
    supabase_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not supabase_url or not service_key:
        print(
            "flag_report: SUPABASE_URL / SUPABASE_SERVICE_KEY missing; "
            "check the private runtime .env",
            file=sys.stderr,
        )
        return 2

    try:
        report = render_markdown(collect_records(supabase_url.rstrip("/"), service_key))
    except FlagReportError as error:
        print(f"flag_report: {error}", file=sys.stderr)
        return 2

    if args.output is None:
        sys.stdout.write(report)
        return 0
    try:
        args.output.write_text(report, encoding="utf-8")
    except OSError as error:
        print(f"flag_report: could not write local report: {error.strerror or 'I/O error'}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

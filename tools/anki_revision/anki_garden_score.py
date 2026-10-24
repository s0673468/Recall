#!/usr/bin/env python3
"""Build a bounded evidence-led Recall card-gardening queue.

Open corrective learner flags come first; likes are standing preferences.
Remaining cards are ranked using mature
Again rates, Anki lapses, slow-answer rates, failed post-edit validation, and
volatile claims whose source recheck is due. This command is read-only.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import re
import sqlite3
from pathlib import Path
from statistics import median

import anki_common as ac


DEFAULT_LIMIT = 30
MIN_LIMIT = 20
MAX_LIMIT = 40
DEFAULT_MIN_REVIEWS = 5
DEFAULT_SLOW_MS = 15_000
DEFAULT_MIN_TIMED_REVIEWS = 3

_TAG_RE = re.compile(r"<[^>]+>")
_VAGUE_RE = re.compile(
    r"\b(explain|describe|discuss|why is|compare and contrast)\b", re.I
)
_ENUM_RE = re.compile(
    r"\b(name (the )?(two|three|four|five|all)|list (the )?|what are the)\b", re.I
)


class GardenError(ValueError):
    """Raised when queue inputs do not satisfy the contract."""


def local_proxy(reps: int, lapses: int, interval: int) -> float:
    reps, lapses, interval = reps or 0, lapses or 0, interval or 0
    rate = lapses / reps if reps else 0.0
    magnitude = min(1.0, lapses / 5.0)
    stuck = 0.0
    if reps >= 4 and interval < 7:
        stuck = min(1.0, (reps - 3) / 6.0) * (1.0 - min(1.0, interval / 7.0))
    return min(1.0, 0.5 * rate + 0.3 * magnitude + 0.2 * stuck)


def rubric_flags(front: str, back: str) -> list[str]:
    front_text = _TAG_RE.sub("", front or "").strip()
    back_text = _TAG_RE.sub("", back or "").strip()
    flags: list[str] = []
    if _VAGUE_RE.search(front_text):
        flags.append("vague_prompt")
    if _ENUM_RE.search(front_text):
        flags.append("enumeration_prompt")
    if len(back_text) > 240:
        flags.append("long_answer")
    if not back_text:
        flags.append("empty_answer")
    return flags


def _signal_ids(value: object, label: str) -> tuple[set[int], set[str]]:
    if value is None:
        return set(), set()
    rows = (
        value.get("items", value.get("flags", value.get("queue", [])))
        if isinstance(value, dict)
        else value
    )
    if not isinstance(rows, list):
        raise GardenError(f"{label} must be a list or an object containing items")
    nids: set[int] = set()
    guids: set[str] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise GardenError(f"{label}[{index}] must be an object")
        if label == "flags" and (
            row.get("reason") == "like" or row.get("status", "open") != "open"
        ):
            continue
        nid, guid = row.get("nid"), row.get("guid")
        if isinstance(nid, int) and nid > 0:
            nids.add(nid)
        elif isinstance(guid, str) and guid:
            guids.add(guid)
        else:
            raise GardenError(f"{label}[{index}] needs nid or guid")
    return nids, guids


def aggregate_reviews(rows: list[dict[str, object]]) -> dict[str, dict[str, object]]:
    grouped: dict[str, dict[str, object]] = {}
    for row in rows:
        guid = row.get("guid")
        if not isinstance(guid, str) or not guid:
            continue
        item = grouped.setdefault(guid, {"reviews": 0, "again": 0, "elapsed_ms": []})
        item["reviews"] = int(item["reviews"]) + 1
        if row.get("rating") == 1:
            item["again"] = int(item["again"]) + 1
        elapsed = row.get("elapsed_ms")
        if isinstance(elapsed, (int, float)) and elapsed >= 0:
            item["elapsed_ms"].append(float(elapsed))
    return grouped


def rank_notes(
    notes: list[dict[str, object]],
    *,
    review_metrics: dict[str, dict[str, object]] | None = None,
    flags: object = None,
    validation_failures: object = None,
    recheck_due: object = None,
    quality_scores: dict[int, dict[str, object]] | None = None,
    limit: int = DEFAULT_LIMIT,
    min_reviews: int = DEFAULT_MIN_REVIEWS,
    slow_ms: int = DEFAULT_SLOW_MS,
    min_timed_reviews: int = DEFAULT_MIN_TIMED_REVIEWS,
) -> list[dict[str, object]]:
    if not MIN_LIMIT <= limit <= MAX_LIMIT:
        raise GardenError(f"limit must be between {MIN_LIMIT} and {MAX_LIMIT}")
    if min_reviews < 1 or min_timed_reviews < 1 or slow_ms < 1:
        raise GardenError("review thresholds must be positive")
    review_metrics = review_metrics or {}
    flag_nids, flag_guids = _signal_ids(flags, "flags")
    failed_nids, failed_guids = _signal_ids(validation_failures, "validation_failures")
    due_nids, due_guids = _signal_ids(recheck_due, "recheck_due")
    liked_nids, liked_guids = set(), set()
    if quality_scores:
        flag_rows = (
            flags.get("items", flags.get("flags", flags.get("queue", [])))
            if isinstance(flags, dict) else flags or []
        )
        liked_nids, liked_guids = _signal_ids(
            [row for row in flag_rows
             if row.get("reason") == "like" and row.get("status", "open") == "open"],
            "likes",
        )

    scored: list[dict[str, object]] = []
    for note in notes:
        nid, guid = int(note["nid"]), str(note["guid"])
        predictions = [
            quality_scores[cid] for cid in note.get("card_ids", [])
            if quality_scores and cid in quality_scores
        ]
        if quality_scores and (
            nid in liked_nids or guid in liked_guids
            or any("liked_keep_style" in row.get("top_reasons", []) for row in predictions)
        ):
            continue
        is_flagged = nid in flag_nids or guid in flag_guids
        failed_validation = nid in failed_nids or guid in failed_guids
        due = nid in due_nids or guid in due_guids
        metrics = review_metrics.get(guid, {})
        reviews = int(metrics.get("reviews", 0))
        again = int(metrics.get("again", 0))
        elapsed = [float(value) for value in metrics.get("elapsed_ms", [])]

        local = local_proxy(
            int(note.get("reps", 0)),
            int(note.get("lapses", 0)),
            int(note.get("ivl", 0)),
        )
        again_rate = again / reviews if reviews >= min_reviews else None
        slow_rate = (
            sum(value >= slow_ms for value in elapsed) / len(elapsed)
            if len(elapsed) >= min_timed_reviews
            else None
        )
        score = 0.45 * local
        if again_rate is not None:
            score += 0.35 * again_rate
        if slow_rate is not None:
            score += 0.15 * slow_rate
        if failed_validation:
            score += 0.75
        if due:
            score += 0.35
        quality_flags = rubric_flags(
            str(note.get("front", "")), str(note.get("back", ""))
        )
        score += min(0.15, 0.04 * len(quality_flags))
        reasons = []
        if is_flagged:
            reasons.append("open_flag")
        if failed_validation:
            reasons.append("material_change_validation_failed")
        if due:
            reasons.append("volatile_recheck_due")
        if again_rate is not None:
            reasons.append("mature_again_rate")
        if slow_rate is not None:
            reasons.append("slow_answer_rate")
        if int(note.get("lapses", 0)):
            reasons.append("anki_lapses")
        reasons.extend(quality_flags)
        if predictions:
            # One note may own several cards; use the largest gardening signal.
            score += max(
                0.25 * (1 - float(row["quality_score"])) + 0.20 * float(row["forget_score"])
                for row in predictions
            )
            reasons.append("local_card_quality_model")
        scored.append(
            {
                "nid": nid,
                "guid": guid,
                "priority": round(min(1.0, score), 4),
                "lane": "flagged" if is_flagged else "scored",
                "reasons": reasons,
                "signals": {
                    "reviews": reviews,
                    "again": again,
                    "again_rate": round(again_rate, 4)
                    if again_rate is not None
                    else None,
                    "timed_reviews": len(elapsed),
                    "median_elapsed_ms": round(median(elapsed)) if elapsed else None,
                    "slow_rate": round(slow_rate, 4) if slow_rate is not None else None,
                    "reps": int(note.get("reps", 0)),
                    "lapses": int(note.get("lapses", 0)),
                    "ivl": int(note.get("ivl", 0)),
                },
            }
        )

    scored.sort(
        key=lambda row: (
            0 if row["lane"] == "flagged" else 1,
            -float(row["priority"]),
            -int(row["signals"]["lapses"]),
            int(row["nid"]),
        )
    )
    return scored[:limit]


def load_quality_scores(path: Path | None) -> dict[int, dict[str, object]] | None:
    """Accept the private JSON/CSV output, never copy arbitrary reason text."""
    if path is None:
        return None
    try:
        if path.suffix.lower() == ".csv":
            with path.open(encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
        else:
            rows = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(rows, list):
            raise ValueError
        result = {}
        for row in rows:
            raw_id = row["card_id"]
            if isinstance(raw_id, bool) or not isinstance(raw_id, (int, str)):
                raise ValueError
            cid = int(raw_id)
            quality, forget = row["quality_score"], row["forget_score"]
            if isinstance(quality, bool) or isinstance(forget, bool):
                raise ValueError
            quality, forget = float(quality), float(forget)
            if cid <= 0 or cid in result or not all(math.isfinite(v) and 0 <= v <= 1 for v in (quality, forget)):
                raise ValueError
            reasons = row.get("top_reasons", [])
            if isinstance(reasons, str):
                reasons = reasons.split(";")
            if not isinstance(reasons, list):
                raise ValueError
            result[cid] = {"quality_score": quality, "forget_score": forget,
                           "top_reasons": ["liked_keep_style"] if "liked_keep_style" in reasons else []}
        return result
    except (OSError, ValueError, TypeError, KeyError):
        raise GardenError("invalid local card quality scores") from None


def load_quality_card_map(path: Path) -> dict[int, list[int]]:
    """Explicit cloud card_id -> local nid links; never guess identity domains."""
    try:
        rows = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(rows, list):
            raise ValueError
        result, seen = {}, set()
        for row in rows:
            cid, nid = row["card_id"], row["nid"]
            if type(cid) is not int or type(nid) is not int or min(cid, nid) <= 0 or cid in seen:
                raise ValueError
            seen.add(cid)
            result.setdefault(nid, []).append(cid)
        return result
    except (OSError, ValueError, TypeError, KeyError):
        raise GardenError("invalid local card quality ID map") from None


def _read_optional(path: Path | None) -> object:
    if path is None:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GardenError(f"could not read {path}: {error}") from error


def load_cloud_env(path: str | None) -> dict[str, str]:
    return ac.parse_env_file(path)


def fetch_cloud_signals(
    env: dict[str, str],
    *,
    include_likes: bool = False,
) -> tuple[list[dict[str, object]], object, str]:
    url = env.get("SUPABASE_URL") or os.environ.get("SUPABASE_URL")
    key = env.get("SUPABASE_SERVICE_KEY") or os.environ.get("SUPABASE_SERVICE_KEY")
    user_id = env.get("SUPABASE_USER_ID") or os.environ.get("SUPABASE_USER_ID")
    if not url or not key or not user_id:
        return [], None, "credentials unavailable"
    try:
        from supabase import create_client

        client = create_client(url, key)
        reviews: list[dict[str, object]] = []
        start = 0
        while True:
            chunk = (
                client.table("review_log")
                .select("guid,rating,elapsed_ms")
                .eq("user_id", user_id)
                .range(start, start + 999)
                .execute()
                .data
            )
            reviews.extend(chunk)
            if len(chunk) < 1000:
                break
            start += 1000
        flag_query = (
            client.table("note_flags")
            .select("guid,reason,status")
            .eq("user_id", user_id)
            .eq("status", "open")
        )
        # Model scores may predate a new like; protect using current flags too.
        if not include_likes:
            flag_query = flag_query.neq("reason", "like")
        flags = flag_query.execute().data
        return reviews, flags, f"reviews={len(reviews)} open_flags={len(flags)}"
    except Exception as error:
        return [], None, f"{type(error).__name__}: {str(error)[:80]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path(ac.LIVE_DB))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--min-reviews", type=int, default=DEFAULT_MIN_REVIEWS)
    parser.add_argument("--slow-ms", type=int, default=DEFAULT_SLOW_MS)
    parser.add_argument(
        "--min-timed-reviews", type=int, default=DEFAULT_MIN_TIMED_REVIEWS
    )
    parser.add_argument("--flags-file", type=Path)
    parser.add_argument("--validation-failures", type=Path)
    parser.add_argument("--recheck-due", type=Path)
    parser.add_argument("--quality-scores", type=Path, help="optional private card-quality CSV/JSON")
    parser.add_argument("--quality-card-map", type=Path, help="private JSON list of cloud card_id/local nid pairs")
    parser.add_argument("--cloud-env", type=Path)
    parser.add_argument("--no-cloud", action="store_true")
    args = parser.parse_args()
    try:
        if bool(args.quality_scores) != bool(args.quality_card_map):
            raise GardenError("quality scores and their explicit card ID map must be supplied together")
        quality_scores = load_quality_scores(args.quality_scores)
        quality_card_map = load_quality_card_map(args.quality_card_map) if args.quality_card_map else {}
        if quality_scores is not None and set(quality_scores) - {cid for ids in quality_card_map.values() for cid in ids}:
            raise GardenError("quality scores contain unmapped card IDs")
        flags = _read_optional(args.flags_file)
        cloud_note = "skipped"
        cloud_reviews: list[dict[str, object]] = []
        if not args.no_cloud:
            env_path = ac.resolve_cloud_env(
                str(args.cloud_env) if args.cloud_env else None
            )
            cloud_reviews, cloud_flags, cloud_note = fetch_cloud_signals(
                load_cloud_env(env_path), include_likes=bool(quality_scores)
            )
            if flags is None:
                flags = cloud_flags
            if quality_scores and flags is None:
                raise GardenError(
                    "current like flags unavailable; supply --flags-file or "
                    "explicitly use --no-cloud with current offline inputs"
                )
        connection = ac.connect(str(args.db), ro=True)
        try:
            notes = []
            for nid, guid, tags, flds, reps, lapses, ivl in connection.execute(
                "SELECT n.id,n.guid,n.tags,n.flds,c.reps,c.lapses,c.ivl "
                "FROM notes n JOIN cards c ON c.nid=n.id GROUP BY n.id"
            ):
                fields = str(flds or "").split(ac.FSEP)
                notes.append(
                    {
                        "nid": nid,
                        "guid": guid,
                        "tags": str(tags or "").split(),
                        "front": fields[0] if fields else "",
                        "back": fields[1] if len(fields) > 1 else "",
                        "reps": reps,
                        "lapses": lapses,
                        "ivl": ivl,
                        "card_ids": quality_card_map.get(nid, []),
                    }
                )
        finally:
            connection.close()
        if quality_scores:
            local_nids = {note["nid"] for note in notes}
            if any(nid not in local_nids and any(cid in quality_scores for cid in ids)
                   for nid, ids in quality_card_map.items()):
                raise GardenError("quality card ID map references missing local notes")
        queue = rank_notes(
            notes,
            review_metrics=aggregate_reviews(cloud_reviews),
            flags=flags,
            validation_failures=_read_optional(args.validation_failures),
            recheck_due=_read_optional(args.recheck_due),
            quality_scores=quality_scores,
            limit=args.limit,
            min_reviews=args.min_reviews,
            slow_ms=args.slow_ms,
            min_timed_reviews=args.min_timed_reviews,
        )
    except (GardenError, sqlite3.Error) as error:
        parser.exit(1, f"garden scoring rejected: {error}\n")
    payload = {
        "schema": "recall.garden-queue/v2",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "cloud_note": cloud_note,
        "params": {
            "limit": args.limit,
            "min_reviews": args.min_reviews,
            "slow_ms": args.slow_ms,
            "min_timed_reviews": args.min_timed_reviews,
        },
        "count": len(queue),
        "queue": queue,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"garden queue={len(queue)} cloud={cloud_note} -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

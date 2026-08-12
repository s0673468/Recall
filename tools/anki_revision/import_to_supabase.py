#!/usr/bin/env python3
"""One-way, idempotent import: desktop collection.anki2 -> Supabase (anki-review).

Content flows DOWN only. FSRS scheduling state is seeded ONLY for cards the cloud
has not reviewed yet (`cloud_seen = false`); once the app has reviewed a card the
importer never touches its scheduling again. This is what makes re-running safe.

Designed to run unattended on the M1 hub against a downloaded copy of the
collection (see ~/Code/_archive/Anki-management/ANKI_WEB_PLAN.md section 4). For
local/manual runs it
reads the live Mac collection by default.

Env:
  SUPABASE_URL          https://<ref>.supabase.co
  SUPABASE_SERVICE_KEY  service-role (secret) key -- bypasses RLS. Keep out of git.
  SUPABASE_USER_ID      a0000000-0000-4000-8000-000000000001
  ANKI_COLLECTION       optional path to a collection.anki2 copy

Dry run (no network, verifies parsing only):
  python import_to_supabase.py --dry-run
"""

import os
import re
import sys
import json
import shutil
import struct
import tempfile
import datetime as dt

# The importer and Anki schema helpers are versioned together. Production may
# invoke this file from a thin runtime wrapper, but it never imports mutable
# installed-skill code.
from anki_common import connect, deck_name_to_id

LIVE_DB = os.environ.get(
    "ANKI_COLLECTION",
    os.path.expanduser("~/Library/Application Support/Anki2/User 1/collection.anki2"),
)
USER_ID = os.environ.get("SUPABASE_USER_ID", "a0000000-0000-4000-8000-000000000001")
LATEX = re.compile(
    r"\\\(|\\\[|\$\$"
)  # math delimiters: inline \( … \), display \[ … \] / $$ … $$
FSEP = "\x1f"  # Anki field separator inside notes.flds
FSRS_PARAMETERS_FIELD = 6  # Packed 21-float vector in Anki deck_config.config.
FSRS_PARAMETERS_COUNT = 21
FSRS_SETTINGS_KEY = "fsrs_params"


def _iso(epoch):
    """Epoch seconds (or ms) -> ISO-8601 UTC, or None."""
    if not epoch:
        return None
    if epoch > 1e12:  # someone stored milliseconds
        epoch /= 1000.0
    return _safe_iso(epoch)


def _safe_iso(epoch):
    """Epoch seconds -> ISO-8601 UTC; None if it's out of a sane date range
    (filtered-deck / corrupt due values can be astronomically large)."""
    try:
        return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
    except (ValueError, OverflowError, OSError):
        return None


def _read_varint(buf, offset):
    """Read a protobuf-style varint from buf at offset -> (value, new_offset)."""
    shift, value = 0, 0
    while offset < len(buf):
        b = buf[offset]
        offset += 1
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            return value, offset
        shift += 7
    raise ValueError("truncated varint")


def _packed_float_field(buf, target_field):
    """Return a packed little-endian float field from Anki's deck config blob."""
    offset = 0
    while offset < len(buf):
        tag, offset = _read_varint(buf, offset)
        field, wire_type = tag >> 3, tag & 0x7
        if wire_type == 2:
            length, offset = _read_varint(buf, offset)
            data = buf[offset : offset + length]
            offset += length
            if field == target_field and length % 4 == 0:
                return list(struct.unpack("<" + "f" * (length // 4), data))
        elif wire_type == 0:
            _, offset = _read_varint(buf, offset)
        elif wire_type == 5:
            offset += 4
        else:
            raise ValueError(f"unsupported deck config wire type: {wire_type}")
    return None


def fsrs_settings_payload(con):
    """Extract the desktop FSRS parameter vector for user_settings seeding."""
    row = con.execute(
        "SELECT id, name, config FROM deck_config ORDER BY id LIMIT 1"
    ).fetchone()
    if not row:
        return None
    deck_config_id, deck_config_name, config = row
    params = _packed_float_field(config, FSRS_PARAMETERS_FIELD)
    if not params or len(params) != FSRS_PARAMETERS_COUNT:
        return None
    return {
        "user_id": USER_ID,
        "settings_key": FSRS_SETTINGS_KEY,
        "settings_value": {
            "parameters": [round(float(v), 8) for v in params],
            "desired_retention": 0.9,
            "source": "anki_deck_config",
            "deck_config_id": deck_config_id,
            "deck_config_name": deck_config_name,
        },
    }


def build_payloads(con):
    """Read the collection -> (decks, notes, card_seed, settings). Pure read.

    card_seed maps guid -> the FSRS seed dict to use IF the cloud hasn't seen the
    card yet. `due` for a review card is days since collection creation (col.crt),
    NOT unix epoch -- convert against crt.
    """
    crt = con.execute("SELECT crt FROM col").fetchone()[0]
    name_to_did = deck_name_to_id(con)
    decks = [
        {"user_id": USER_ID, "deck_id": did, "name": name, "deleted": False}
        for name, did in name_to_did.items()
    ]

    rows = con.execute(
        """
        SELECT n.guid, c.did, n.mid, n.flds, n.tags, n.mod,
               c.data, c.due, c.reps, c.lapses, c.type, c.queue
        FROM notes n JOIN cards c ON c.nid = n.id
        """
    ).fetchall()

    notes, card_seed = [], {}
    for guid, did, mid, flds, tags, mod, data, due, reps, lapses, ctype, queue in rows:
        parts = flds.split(FSEP)
        front = parts[0] if parts else ""
        back = parts[1] if len(parts) > 1 else ""
        notes.append(
            {
                "user_id": USER_ID,
                "guid": guid,
                "deck_id": did,
                "mid": mid,
                "front": front,
                "back": back,
                "tags": tags.strip(),
                "has_latex": bool(LATEX.search(front) or LATEX.search(back)),
                "anki_mod": mod,
                "deleted": False,
            }
        )
        fsrs = json.loads(data) if data else {}
        # `due` units depend on card type:
        #   type 0 (new)         -> position int (no real due date)
        #   type 2 (review)      -> days since collection creation (col.crt)
        #   type 1/3 (re/learning) -> unix epoch SECONDS for the next step
        if ctype == 0:
            state, due_abs = 0, None
        elif ctype == 2:
            state, due_abs = 2, _safe_iso(crt + due * 86400)
        else:
            state = 1 if ctype == 1 else 3
            due_abs = _safe_iso(due)
        card_seed[guid] = {
            "user_id": USER_ID,
            "guid": guid,
            "stability": float(fsrs.get("s", 0.0)),
            "difficulty": float(fsrs.get("d", 0.0)),
            "state": state,
            "due": due_abs,
            "reps": reps,
            "lapses": lapses,
            "last_review": _iso(fsrs.get("lrt")),
            # desktop suspension (queue == -1) -> Recall dormancy. Importer-owned
            # for ALL cards (like content), orthogonal to the FSRS columns.
            "suspended": queue == -1,
        }
    return decks, notes, card_seed, fsrs_settings_payload(con)


def _fetch_all(sb, table_name, columns, **eq):
    """Fetch ALL matching rows. PostgREST caps a single GET at 1000 rows, so page."""
    rows, start = [], 0
    while True:
        q = sb.table(table_name).select(columns)
        for col, val in eq.items():
            q = q.eq(col, val)
        chunk = q.range(start, start + 999).execute().data
        rows.extend(chunk)
        if len(chunk) < 1000:
            return rows
        start += 1000


def run(sb):
    """Do the one-way upsert against an already-built Supabase client."""
    tmp = os.path.join(tempfile.gettempdir(), "anki_import_copy.anki2")
    shutil.copy2(LIVE_DB, tmp)  # snapshot so an open Anki can't torn-read us
    con = connect(tmp, ro=True)
    decks, notes, card_seed, fsrs_settings = build_payloads(con)

    sb.table("decks").upsert(decks, on_conflict="user_id,deck_id").execute()
    sb.table("notes").upsert(notes, on_conflict="user_id,guid").execute()
    if fsrs_settings and not _fetch_all(
        sb,
        "user_settings",
        "settings_key",
        user_id=USER_ID,
        settings_key=FSRS_SETTINGS_KEY,
    ):
        sb.table("user_settings").insert(fsrs_settings).execute()

    note_ids = {
        r["guid"]: r["id"] for r in _fetch_all(sb, "notes", "id,guid", user_id=USER_ID)
    }
    seen = {
        r["guid"]
        for r in _fetch_all(sb, "cards", "guid", user_id=USER_ID, cloud_seen=True)
    }

    # `suspended` shipped in migration 002; probe so a not-yet-migrated cloud
    # (e.g. the autosync job racing the migration) degrades to the old payload
    # instead of erroring on an unknown column.
    try:
        sb.table("cards").select("suspended").limit(1).execute()
        has_suspended = True
    except Exception:
        has_suspended = False
        print("note: cards.suspended column absent — skipping suspension sync")

    # Two homogeneous upserts: PostgREST derives the column list from the payload,
    # so mixing full rows with base-only rows either nulls out scheduling on seen
    # cards or inserts new ones without it (NOT NULL violation on `stability`).
    seed_rows, link_rows = [], []
    for guid, seed in card_seed.items():
        base = {
            "user_id": USER_ID,
            "guid": guid,
            "note_id": note_ids[guid],
            "deleted": False,
        }
        if has_suspended:
            base["suspended"] = seed["suspended"]
        if guid not in seen:  # THE GUARD: only seed unreviewed cards
            base.update(
                {
                    k: v
                    for k, v in seed.items()
                    if k not in ("user_id", "guid", "suspended")
                }
            )
            if not has_suspended:
                base.pop("suspended", None)
            seed_rows.append(base)
        else:
            link_rows.append(base)
    if seed_rows:
        sb.table("cards").upsert(seed_rows, on_conflict="user_id,guid").execute()
    if link_rows:
        sb.table("cards").upsert(link_rows, on_conflict="user_id,guid").execute()

    live = {n["guid"] for n in notes}
    stale = [g for g in note_ids if g not in live]
    if stale:
        sb.table("notes").update({"deleted": True}).eq("user_id", USER_ID).in_(
            "guid", stale
        ).execute()
        sb.table("cards").update({"deleted": True}).eq("user_id", USER_ID).in_(
            "guid", stale
        ).execute()

    seeded = sum(1 for g in card_seed if g not in seen)
    print(
        f"decks={len(decks)} notes={len(notes)} cards_seeded={seeded} stale={len(stale)}"
    )


def dry_run():
    """Parse the collection and report counts + a sample, without any network."""
    con = connect(LIVE_DB, ro=True)
    decks, notes, card_seed, fsrs_settings = build_payloads(con)
    latex = sum(1 for n in notes if n["has_latex"])
    review = sum(1 for c in card_seed.values() if c["state"] == 2)
    print(
        f"decks={len(decks)} notes={len(notes)} cards={len(card_seed)} "
        f"has_latex={latex} review_state={review} new_state={len(card_seed) - review}"
    )
    if fsrs_settings:
        params = fsrs_settings["settings_value"]["parameters"]
        print(f"fsrs_params={len(params)} first={params[0]} last={params[-1]}")
    print("decks:", [d["name"] for d in decks])
    g0 = notes[0]["guid"]
    print(
        "sample note:",
        json.dumps(
            {
                k: (v[:60] + "..." if isinstance(v, str) and len(v) > 60 else v)
                for k, v in notes[0].items()
            },
            ensure_ascii=False,
        ),
    )
    print("sample card:", json.dumps(card_seed[g0], ensure_ascii=False))


if __name__ == "__main__":
    if "--dry-run" in sys.argv:
        dry_run()
    else:
        try:
            from dotenv import load_dotenv

            load_dotenv(
                os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
            )
        except ImportError:
            pass
        if not os.environ.get("SUPABASE_SERVICE_KEY"):
            sys.exit("SUPABASE_SERVICE_KEY is empty — paste it into cloud/.env first.")
        from supabase import create_client

        client = create_client(
            os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"]
        )
        run(client)

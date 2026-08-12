#!/usr/bin/env python3
"""Shared helpers for the anki-revision engine.

Every script that reads or writes the collection imports from here, so the
delicate bits — how `sfld` and `csum` are computed, how the `unicase` collation
is registered — are defined exactly once. If `csum` ever disagrees with what
Anki itself would compute, Anki's duplicate detection breaks silently, so this
is the single source of truth for that logic.

Nothing here writes the database; it only provides functions the writers use.
"""

import hashlib
import html
import os
import re
import secrets
import sqlite3
import string

# Defaults. The live collection is the source of truth; job artifacts (batches,
# changesets, logs, reports) land under ROOT/jobs/<job>/.
LIVE_DB = os.path.expanduser(
    "~/Library/Application Support/Anki2/User 1/collection.anki2"
)
BACKUP_DIR = os.path.expanduser("~/Library/Application Support/Anki2/User 1/backups")

# The old ~/Code/Anki checkout was split: job/script/data artifacts moved to
# _archive/Anki-management, while the Supabase importer and its .env moved to
# _runtime/recall-anki-sync. Set ANKI_ROOT to point the job tree elsewhere.
ROOT = os.path.expanduser(
    os.environ.get("ANKI_ROOT") or "~/Code/_archive/Anki-management"
)

# Where Supabase creds (SUPABASE_URL / SUPABASE_SERVICE_KEY) may live, most
# authoritative first; $ANKI_CLOUD_ENV overrides the list. Only the recall sync
# importer holds them today — add further locations here if that changes.
CLOUD_ENV_CANDIDATES = ("~/Code/_runtime/recall-anki-sync/.env",)

# Field separator Anki uses between fields inside notes.flds, and the separator
# inside decks.name for nested decks ("Parent\x1fChild" renders as "Parent::Child").
FSEP = "\x1f"

# Fallback note-type id for the Basic type (every note in the collection is
# Basic). Prefer basic_mid() which looks it up live; this is only a backstop.
MID_BASIC_FALLBACK = 1756671321824


def resolve_cloud_env(explicit: str = None) -> str:
    """Path of the first readable Supabase .env, or None if none exists.

    Order: `explicit` (a --cloud-env flag), then $ANKI_CLOUD_ENV, then
    CLOUD_ENV_CANDIDATES. A path given explicitly but missing raises instead of
    falling through — silently trying the next candidate would hide a typo and
    read a different project's credentials.
    """
    for source, path in (
        ("--cloud-env", explicit),
        ("$ANKI_CLOUD_ENV", os.environ.get("ANKI_CLOUD_ENV")),
    ):
        if path:
            full = os.path.expanduser(path)
            if not os.path.exists(full):
                raise FileNotFoundError(f"{source} points at a missing file: {full}")
            return full
    for cand in CLOUD_ENV_CANDIDATES:
        full = os.path.expanduser(cand)
        if os.path.exists(full):
            return full
    return None


def parse_env_file(path: str) -> dict:
    """Parse a KEY=value .env into a dict. No value is ever printed."""
    conf = {}
    if not path:
        return conf
    try:
        with open(path, encoding="utf-8") as fp:
            for line in fp:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    conf[k.strip()] = v.strip()
    except OSError:
        pass
    return conf


def cloud_env_help() -> str:
    """Message listing every place creds were looked for. Never prints values."""
    tried = "\n".join(f"    {os.path.expanduser(c)}" for c in CLOUD_ENV_CANDIDATES)
    return (
        "no Supabase credentials found.\n"
        "  Looked for a .env at:\n"
        f"{tried}\n"
        "  and for SUPABASE_URL / SUPABASE_SERVICE_KEY in the environment.\n"
        "  Point ANKI_CLOUD_ENV (or --cloud-env) at the right .env file."
    )


def strip_html(s: str) -> str:
    """Plain text of a field — what Anki stores in `sfld` and hashes for `csum`."""
    return html.unescape(re.sub(r"<[^>]+>", "", s))


def csum(first_field_html: str) -> int:
    """Anki's note checksum: first 8 hex of sha1 of the stripped first field."""
    return int(hashlib.sha1(strip_html(first_field_html).encode()).hexdigest()[:8], 16)


def guid() -> str:
    """A fresh 10-char note guid (Anki's sync identity for a note)."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(10))


def _unicase(a: str, b: str) -> int:
    return (a.lower() > b.lower()) - (a.lower() < b.lower())


def connect(db: str = LIVE_DB, ro: bool = False) -> sqlite3.Connection:
    """Open the collection with the `unicase` collation Anki's schema references.

    Pass ro=True for any read-only step (prep, lint, validate) so a stray write
    can't happen and an open Anki instance can't be blocked.
    """
    if ro:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    else:
        con = sqlite3.connect(db)
    con.create_collation("unicase", _unicase)
    return con


def basic_mid(con: sqlite3.Connection) -> int:
    """Live id of the Basic note type, falling back to the known constant."""
    try:
        row = con.execute("select id from notetypes where name='Basic'").fetchone()
        if row:
            return row[0]
    except sqlite3.Error:
        pass
    return MID_BASIC_FALLBACK


def deck_name_to_id(con: sqlite3.Connection) -> dict:
    """Map human deck names ('Parent::Child') to deck ids."""
    return {
        name.replace(FSEP, "::"): did
        for did, name in con.execute("select id, name from decks")
    }


def job_dir(root: str, job: str) -> str:
    return os.path.join(root, "jobs", job)


def merge_tags(original: str, add, pass_tag: str) -> str:
    """Append `add` tags and the pass tag to a space-delimited tag string,
    preserving Anki's leading/trailing-space convention and avoiding dupes."""
    parts = original.split()
    for t in list(add or []) + [pass_tag]:
        if t and t not in parts:
            parts.append(t)
    return " " + " ".join(parts) + " "

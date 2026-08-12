#!/usr/bin/env python3
"""Recall note_flags bridge — the phone-to-desktop feedback loop.

German flags bad cards mid-review in the Recall app (reasons: wrong / confusing /
too_long / duplicate). Flags land in the anki-review Supabase `note_flags` table.
This script is the ONLY way revision jobs touch that table:

  list      open flags joined to the local collection (nid, deck, front) — feed
            these nids to anki_prep.py --nids-file as a priority revise subset
  resolve   mark a flag resolved with a one-line resolution (what the pass did)
  dismiss   mark a flag dismissed (flag was wrong / card already fine)

Reads creds (SUPABASE_URL / SUPABASE_SERVICE_KEY) from the first .env found in
anki_common.CLOUD_ENV_CANDIDATES — normally ~/Code/_runtime/recall-anki-sync/.env
— overridable with $ANKI_CLOUD_ENV. Exits with a clear error if none is found.
Never writes the Anki DB; never writes any Supabase table except note_flags.status,
resolved_at, resolution.

  python3 anki_flags.py list [--json]
  python3 anki_flags.py list --nids-file /tmp/flag_queue.json   # for anki_prep.py
  python3 anki_flags.py resolve <flag_id> --resolution "split into 2 cards (nid 123, 456)"
  python3 anki_flags.py dismiss <flag_id> --resolution "card already atomic; flag stale"
"""

import argparse
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import anki_common as ac  # noqa: E402

LIVE_DB = os.path.expanduser(
    "~/Library/Application Support/Anki2/User 1/collection.anki2"
)


def creds():
    """(url, key) from the resolved .env, or the environment. Never silent.

    A missing .env used to fall through to whatever SUPABASE_* happened to be
    exported, so a wrong-project or half-set environment looked like success.
    Now the source is always named on stderr, and no source at all is fatal.
    """
    try:
        env_path = ac.resolve_cloud_env()
    except FileNotFoundError as e:
        sys.exit(f"FATAL: {e}")
    conf = ac.parse_env_file(env_path)
    url = conf.get("SUPABASE_URL") or os.environ.get("SUPABASE_URL", "")
    key = conf.get("SUPABASE_SERVICE_KEY") or os.environ.get("SUPABASE_SERVICE_KEY", "")
    if not url or not key:
        sys.exit(f"FATAL: {ac.cloud_env_help()}")
    source = env_path if env_path and conf.get("SUPABASE_URL") else "the environment"
    print(f"[anki_flags] Supabase creds from {source}", file=sys.stderr)
    return url.rstrip("/"), key


def req(url, key, method="GET", path="", params=None, body=None):
    qs = "?" + urllib.parse.urlencode(params) if params else ""
    r = urllib.request.Request(url + "/rest/v1/" + path + qs, method=method)
    r.add_header("apikey", key)
    r.add_header("Authorization", f"Bearer {key}")
    r.add_header("Content-Type", "application/json")
    r.add_header("Prefer", "return=representation")
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(r, data=data, timeout=20) as resp:
        return json.loads(resp.read() or "[]")


def cmd_list(args):
    url, key = creds()
    flags = req(
        url,
        key,
        path="note_flags",
        params={
            "status": "eq.open",
            "order": "flagged_at.asc",
            "select": "id,guid,reason,flagged_at,device",
        },
    )
    # join to the local collection for nid/deck/front (read-only)
    by_guid = {}
    if os.path.exists(LIVE_DB):
        con = ac.connect(LIVE_DB, ro=True)
        name_by_did = {did: name for name, did in ac.deck_name_to_id(con).items()}
        for nid, guid, flds, did in con.execute(
            "select n.id, n.guid, n.flds, c.did from notes n join cards c on c.nid=n.id"
        ):
            by_guid[guid] = {
                "nid": nid,
                "deck": name_by_did.get(did, "?"),
                "front": flds.split("\x1f")[0][:110],
            }
    out = []
    for f in flags:
        local = by_guid.get(f["guid"], {})
        out.append({**f, **local})
    if args.nids_file:
        nids = sorted({f["nid"] for f in out if "nid" in f})
        json.dump(nids, open(args.nids_file, "w"))
        print(f"{len(flags)} open flags -> {len(nids)} local nids -> {args.nids_file}")
    elif args.json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        if not out:
            print("no open flags")
        for f in out:
            print(
                f"#{f['id']} [{f['reason']}] {f.get('deck', '?')} nid={f.get('nid', '?')} "
                f"{f['flagged_at'][:10]} | {f.get('front', '(guid not in local collection)')}"
            )


def cmd_close(args, status):
    url, key = creds()
    rows = req(
        url,
        key,
        method="PATCH",
        path="note_flags",
        params={"id": f"eq.{args.flag_id}", "status": "eq.open"},
        body={
            "status": status,
            "resolved_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "resolution": args.resolution,
        },
    )
    if not rows:
        sys.exit(f"flag #{args.flag_id}: not found or not open")
    print(f"flag #{args.flag_id} -> {status}: {args.resolution}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    lp = sub.add_parser("list")
    lp.add_argument("--json", action="store_true")
    lp.add_argument("--nids-file")
    for name in ("resolve", "dismiss"):
        p = sub.add_parser(name)
        p.add_argument("flag_id", type=int)
        p.add_argument("--resolution", required=True)
    args = ap.parse_args()
    if args.cmd == "list":
        cmd_list(args)
    else:
        cmd_close(args, "resolved" if args.cmd == "resolve" else "dismissed")


if __name__ == "__main__":
    main()

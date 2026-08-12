#!/usr/bin/env python3
"""Dump notes into batches for a revise/dedup job, read-only.

Groups cards by deck and orders by note id (which is a creation timestamp, so
nearby ids are topically clustered — RoPE cards sit next to RoPE cards). Each
batch is a small JSON file an agent can rewrite against the rubric.

Crucially it also writes manifest.json listing every nid dumped. anki_apply.py
checks the eventual changeset covers exactly that set, so a card can't vanish
because an agent forgot to return it.

    python3 anki_prep.py --job revise_ml --deck ML
    python3 anki_prep.py --job revise_all --chunk 8
    python3 anki_prep.py --job fix_suspended --suspended-only
    python3 anki_prep.py --job garden --nids-file garden_queue.json   # gardener subset

--nids-file restricts the dump to a pre-selected set of note ids (e.g. the
Deck-Gardener's garden_queue.json). It intersects with the existing
--deck/--tag/--suspended-only filters; absent, behavior is identical to before.

Output layout under ROOT/jobs/<job>/:
    in/batch_NNN.json   one per chunk  {batch_id, deck, cards:[...]}
    out/                empty, for the workflow's first-pass output (optional)
    verified/           empty, where the verified changeset lands
    manifest.json       {job, mode, chunk, deck_filter, nids:[...]}
"""

import argparse
import json
import os

import anki_common as ac


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--job", required=True, help="job name (namespaces the artifacts)")
    ap.add_argument("--db", default=ac.LIVE_DB)
    ap.add_argument("--root", default=ac.ROOT)
    ap.add_argument("--chunk", type=int, default=8, help="cards per batch")
    ap.add_argument("--deck", default=None, help="only this deck (substring match)")
    ap.add_argument("--tag", default=None, help="only notes carrying this tag")
    ap.add_argument("--suspended-only", action="store_true")
    ap.add_argument("--mode", default="revise", choices=["revise", "dedup"])
    ap.add_argument(
        "--nids-file",
        default=None,
        help="restrict dump to these nids (JSON: list of ints, or list "
        "of objects with an 'nid' key, e.g. garden_queue.json)",
    )
    args = ap.parse_args()

    # Optional pre-selected nid subset (the Deck-Gardener's queue). Accept either
    # a bare list of ints or a list of {"nid": ...} objects; also tolerate the
    # garden_queue.json wrapper {"queue": [...]}. Backward-compatible: when the
    # flag is absent, `wanted` is None and no nid filtering happens.
    wanted = None
    if args.nids_file:
        path = args.nids_file
        if not os.path.isabs(path):
            path = os.path.join(args.root, path)
        with open(path) as fp:
            raw = json.load(fp)
        if isinstance(raw, dict):
            raw = raw.get("queue", raw.get("nids", []))
        wanted = set()
        for item in raw:
            nid = item.get("nid") if isinstance(item, dict) else item
            if nid is not None:
                wanted.add(int(nid))

    con = ac.connect(args.db, ro=True)
    cur = con.cursor()
    decks = {
        i: n.replace(ac.FSEP, "::")
        for i, n in cur.execute("select id, name from decks")
    }

    rows = cur.execute(
        """
        select n.id, c.did, n.tags, c.reps, c.lapses, c.ivl, c.queue, n.flds
        from notes n join cards c on c.nid = n.id
        group by n.id
        order by c.did, n.id
        """
    ).fetchall()

    by_deck, nids = {}, []
    for nid, did, tags, reps, lapses, ivl, queue, flds in rows:
        deck = decks.get(did, "Default")
        if wanted is not None and nid not in wanted:
            continue
        if args.deck and args.deck.lower() not in deck.lower():
            continue
        if args.tag and args.tag not in tags.split():
            continue
        if args.suspended_only and queue != -1:
            continue
        f = flds.split(ac.FSEP)
        by_deck.setdefault(deck, []).append(
            {
                "nid": nid,
                "deck": deck,
                "tags": tags.strip(),
                "reps": reps,
                "lapses": lapses,
                "ivl": ivl,
                "suspended": queue == -1,
                "front": f[0],
                "back": f[1] if len(f) > 1 else "",
            }
        )
        nids.append(nid)
    con.close()

    jd = ac.job_dir(args.root, args.job)
    for sub in ("in", "out", "verified"):
        os.makedirs(os.path.join(jd, sub), exist_ok=True)

    manifest_batches, bn = [], 0
    for deck, cards in by_deck.items():
        for i in range(0, len(cards), args.chunk):
            bn += 1
            bid = f"batch_{bn:03d}"
            with open(os.path.join(jd, "in", f"{bid}.json"), "w") as fp:
                json.dump(
                    {"batch_id": bid, "deck": deck, "cards": cards[i : i + args.chunk]},
                    fp,
                    ensure_ascii=False,
                    indent=1,
                )
            manifest_batches.append(bid)

    manifest = {
        "job": args.job,
        "mode": args.mode,
        "chunk": args.chunk,
        "deck_filter": args.deck,
        "tag_filter": args.tag,
        "suspended_only": args.suspended_only,
        "nids_file": args.nids_file,
        "batches": manifest_batches,
        "nids": sorted(nids),
    }
    with open(os.path.join(jd, "manifest.json"), "w") as fp:
        json.dump(manifest, fp, ensure_ascii=False, indent=1)

    print(f"{len(nids)} notes -> {len(manifest_batches)} batches (chunk={args.chunk})")
    if manifest_batches:
        print("batches:", manifest_batches[0], "..", manifest_batches[-1])
    print("job dir:", jd)
    print(
        "next: run the rewrite/verify Workflow, write verified/batch_*.json, then anki_apply.py"
    )


if __name__ == "__main__":
    main()

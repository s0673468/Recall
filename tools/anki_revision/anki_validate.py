#!/usr/bin/env python3
"""Structural health check of the collection — run right after an --apply.

`anki_lint.py` checks card *content*; this checks the *database structure* — the
invariants Anki itself relies on. Catches the ways a bad write can leave the DB
subtly broken even though every individual card looks fine.

Checks:
  - pragma integrity_check == 'ok'
  - 0 orphan cards (a card whose note was deleted)
  - 0 noteless notes (a note with no cards)
  - 0 notes with an empty stripped first field (would be unreviewable)
  - reports the note count, and the delta vs --expect if given

Read-only. Exit code 1 if any structural check fails.

    python3 anki_validate.py
    python3 anki_validate.py --expect 1096      # assert a final count
"""

import argparse
import sys

import anki_common as ac


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=ac.LIVE_DB)
    ap.add_argument("--expect", type=int, default=None, help="assert final note count")
    args = ap.parse_args()

    con = ac.connect(args.db, ro=True)
    cur = con.cursor()

    integ = cur.execute("pragma integrity_check").fetchone()[0]
    notes = cur.execute("select count(*) from notes").fetchone()[0]
    cards = cur.execute("select count(*) from cards").fetchone()[0]
    orphans = cur.execute(
        "select count(*) from cards where nid not in (select id from notes)"
    ).fetchone()[0]
    noteless = cur.execute(
        "select count(*) from notes where id not in (select nid from cards)"
    ).fetchone()[0]
    empty_front = 0
    for (flds,) in cur.execute("select flds from notes"):
        if not ac.strip_html(flds.split(ac.FSEP)[0]).strip():
            empty_front += 1
    con.close()

    ok = True

    def check(label, value, good):
        nonlocal ok
        mark = "ok " if good else "FAIL"
        if not good:
            ok = False
        print(f"  [{mark}] {label}: {value}")

    print("=== structural validation ===")
    check("integrity_check", integ, integ == "ok")
    check("orphan cards", orphans, orphans == 0)
    check("noteless notes", noteless, noteless == 0)
    check("empty first field", empty_front, empty_front == 0)
    print(f"  [info] notes: {notes}   cards: {cards}")
    if args.expect is not None:
        check(f"note count == {args.expect}", notes, notes == args.expect)

    print("PASS" if ok else "PROBLEMS FOUND")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

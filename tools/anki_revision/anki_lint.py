#!/usr/bin/env python3
"""Scan the collection for the content/formatting defects that bulk edits cause.

These are the failure classes the 2026 revision passes kept finding — almost all
introduced by imports or copy-paste that silently ate characters:

  - literal TAB in a field (an eaten backslash: ``\\times`` -> TAB+"imes")
  - orphaned LaTeX fragments (``ext{``, ``imes`` with no backslash)
  - ``\\mathbb{E_...}`` wrapping a whole expression
  - missing space after sentence punctuation in one text node ("radian.It's")
  - missing space at a bold/em boundary ("measures<strong>how")
  - untagged notes (every card should carry at least its deck tag)

Read-only. Run after every apply/import; exit code 1 if anything is found, so it
can gate a workflow.

    python3 anki_lint.py                 # live collection
    python3 anki_lint.py --db PATH       # any collection file
    python3 anki_lint.py --json          # machine-readable
"""

import argparse
import html
import json
import re
import sys

import anki_common as ac

TAB = chr(9)
# "x.Y" is legitimate after these — don't flag as a missing space.
OK_BEFORE_DOT = {"vs", "e.g", "i.e", "etc", "approx"}


def text_nodes(field):
    """Text between HTML tags, with MathJax spans removed so LaTeX punctuation
    doesn't trip the prose checks."""
    no_math = re.sub(r"\\\((?:.|\n)*?\\\)|\\\[(?:.|\n)*?\\\]", " ", field)
    return re.split(r"<[^>]+>", no_math)


def lint_field(field):
    issues = []
    if TAB in field:
        i = field.find(TAB)
        issues.append(("literal-tab", field[max(0, i - 30) : i + 30]))
    for pat, name in [
        (r"(?<![\\a-zA-Z])ext\{", "orphan-latex-text{"),
        (r"(?<![\\a-zA-Z])imes\b", "orphan-latex-times"),
        (r"\\mathbb\{E_", "mathbb-wraps-expression"),
        # Recall intentionally supports MathJax's \[ … \] display delimiter.
        # Bare $$ remains unsupported because its parsing differs across Anki
        # and deployed Recall clients.
        (r"\$\$", "unsupported-dollar-display-math"),
    ]:
        m = re.search(pat, field)
        if m:
            issues.append((name, field[max(0, m.start() - 40) : m.end() + 40]))
    for node in text_nodes(field):
        for m in re.finditer(r"([a-zà-ú]+)([.:])([A-ZÀ-Ú][a-zà-ú])", node):
            if m.group(1).lower() in OK_BEFORE_DOT:
                continue
            issues.append(
                ("missing-space", node[max(0, m.start() - 35) : m.end() + 35])
            )
    for m in re.finditer(
        r"[a-zà-ú]<(?:strong|b|em)>[a-zA-Zà-ú]|[a-zà-ú]</(?:strong|b|em)>[a-zà-ú]",
        field,
    ):
        issues.append(("tag-no-space", field[max(0, m.start() - 25) : m.end() + 25]))
    return issues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=ac.LIVE_DB)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    con = ac.connect(args.db, ro=True)
    findings = []
    for nid, tags, flds in con.execute("select id, tags, flds from notes"):
        for idx, field in enumerate(flds.split(ac.FSEP)):
            for kind, ctx in lint_field(field):
                findings.append(
                    {"nid": nid, "field": idx, "kind": kind, "context": ctx}
                )
        if not tags.strip():
            front = re.sub(r"<[^>]+>", "", flds.split(ac.FSEP)[0])
            findings.append(
                {
                    "nid": nid,
                    "field": 0,
                    "kind": "untagged",
                    "context": html.unescape(front)[:60],
                }
            )
    con.close()

    if args.json:
        print(json.dumps(findings, ensure_ascii=False, indent=1))
    else:
        for f in findings:
            print(f"{f['nid']} f{f['field']} [{f['kind']}] {f['context']!r}")
        if any(f["kind"] == "unsupported-dollar-display-math" for f in findings):
            print(r"note: use supported MathJax \[ … \] instead of $$ … $$.")
        print(f"--- {len(findings)} issue(s)")
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()

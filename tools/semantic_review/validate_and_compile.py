#!/usr/bin/env python3
"""Validate semantic card reviews and compile guarded Anki apply artifacts.

This tool cannot access Anki or Supabase. It accepts read-only concept bundles,
review JSON, and a prepared Anki job, then writes a new verified changeset tree.
The existing ``anki_apply.py`` remains the only collection writer.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Any


VALID_ACTIONS = {"keep", "edit", "split", "delete"}
VALID_REVISION_KINDS = {"wording", "material"}
REVISION_AT_FORMAT = "%Y%m%dT%H%M%SZ"
SVG_ROOT = "{http://www.w3.org/2000/svg}svg"
REQUIRED_REVIEW_KEYS = {
    "node_id",
    "summary",
    "sources",
    "card_changes",
    "new_cards",
    "node_moves",
    "primer",
    "proposed_nodes",
    "unresolved",
}


class ReviewError(ValueError):
    """Raised when semantic review artifacts are unsafe to compile."""


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReviewError(f"{path}: unreadable JSON: {error}") from error


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReviewError(f"{label} must be a non-empty string")
    return value


def _validate_study_text(value: str, label: str) -> None:
    controls = sorted(
        {
            ord(character)
            for character in value
            if ord(character) < 32 and character not in "\n\r"
        }
    )
    if controls:
        raise ReviewError(f"{label} contains a control character: {controls}")
    if any(delimiter in value for delimiter in (r"\\(", r"\\)", r"\\[", r"\\]")):
        raise ReviewError(f"{label} contains a double-escaped MathJax delimiter")


def _validate_card_payload(card: object, label: str) -> dict[str, object]:
    if not isinstance(card, dict):
        raise ReviewError(f"{label} must be an object")
    front = _require_string(card.get("front"), f"{label}.front")
    back = _require_string(card.get("back"), f"{label}.back")
    _validate_study_text(front, f"{label}.front")
    _validate_study_text(back, f"{label}.back")
    tags_add = card.get("tags_add", [])
    tags_remove = card.get("tags_remove", [])
    for value, field in ((tags_add, "tags_add"), (tags_remove, "tags_remove")):
        if not isinstance(value, list) or not all(
            isinstance(tag, str) and tag for tag in value
        ):
            raise ReviewError(f"{label}.{field} must be a list of non-empty strings")
        if len(value) != len(set(value)):
            raise ReviewError(f"{label}.{field} contains duplicates")
    if set(tags_add).intersection(tags_remove):
        raise ReviewError(f"{label} adds and removes the same tag")
    return {
        "front": front,
        "back": back,
        "tags_add": tags_add,
        "tags_remove": tags_remove,
    }


def _load_primer_validator(metis_root: Path):
    checker_path = metis_root / "scripts" / "check_primers.py"
    if not checker_path.is_file():
        raise ReviewError(f"METIS primer validator missing: {checker_path}")
    spec = importlib.util.spec_from_file_location(
        "recall_semantic_primer_check", checker_path
    )
    if spec is None or spec.loader is None:
        raise ReviewError(f"could not load METIS primer validator: {checker_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.validate_primer


def _validate_primer_candidate(
    html: str,
    *,
    node_id: str,
    metis_root: Path | None,
) -> None:
    if metis_root is None:
        return
    validate_primer = _load_primer_validator(metis_root)
    with tempfile.TemporaryDirectory() as temp_dir:
        path = Path(temp_dir) / f"{node_id}.html"
        path.write_text(html, encoding="utf-8")
        errors = validate_primer(path)
    if errors:
        raise ReviewError(f"{node_id}: primer validation failed: {'; '.join(errors)}")


def _primer_filename(value: str, label: str) -> str:
    candidate = Path(value)
    if candidate.name != value or value in {"", ".", ".."}:
        raise ReviewError(f"{label} must be a plain filename component")
    filename = value if value.endswith(".html") else f"{value}.html"
    if filename in {".html", "..html"}:
        raise ReviewError(f"{label} must name an HTML file")
    return filename


def _batch_name(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or Path(value).name != value:
        raise ReviewError(f"{label} must be a plain filename component")
    if value in {".", "..", "batch_additions"}:
        raise ReviewError(f"{label} is reserved or invalid")
    return value


def _validate_figure(
    review: dict[str, object],
    bundle: dict[str, object],
    *,
    node_id: str,
) -> dict[str, object]:
    original_path = bundle.get("figure_path")
    candidate = review.get("figure")
    if original_path is None:
        if candidate is not None and (
            not isinstance(candidate, dict) or candidate.get("action") != "missing"
        ):
            raise ReviewError(
                f"{node_id}: cluster without a figure must use action missing"
            )
        return {
            "action": "missing",
            "path": None,
            "rationale": "No figure is attached to this cluster.",
            "svg": None,
        }
    source_path = Path(str(original_path))
    if not source_path.is_file():
        raise ReviewError(f"{node_id}: original figure is missing: {source_path}")
    try:
        original_root = ET.fromstring(source_path.read_text(encoding="utf-8"))
    except (OSError, ET.ParseError) as error:
        raise ReviewError(
            f"{node_id}: original figure is invalid XML: {error}"
        ) from error
    if original_root.tag.rsplit("}", 1)[-1] != "svg":
        raise ReviewError(f"{node_id}: original figure root must be svg")
    if any(
        element.tag.rsplit("}", 1)[-1] == "script" for element in original_root.iter()
    ):
        raise ReviewError(f"{node_id}: original figure cannot contain script")
    if candidate is None:
        return {
            "action": "unreviewed",
            "path": original_path,
            "rationale": "Figure review was not supplied.",
            "svg": None,
        }
    if not isinstance(candidate, dict):
        raise ReviewError(f"{node_id}.figure must be an object")
    if candidate.get("path") != original_path:
        raise ReviewError(f"{node_id}.figure path must match the input bundle")
    action = candidate.get("action")
    if action not in {"keep", "edit"}:
        raise ReviewError(f"{node_id}.figure action must be keep or edit")
    _require_string(candidate.get("rationale"), f"{node_id}.figure.rationale")
    svg = candidate.get("svg")
    if action == "keep":
        if svg is not None:
            raise ReviewError(f"{node_id}: kept figure SVG must be null")
    else:
        svg = _require_string(svg, f"{node_id}.figure.svg")
        try:
            root = ET.fromstring(svg)
        except ET.ParseError as error:
            raise ReviewError(
                f"{node_id}: edited figure is invalid XML: {error}"
            ) from error
        if root.tag.rsplit("}", 1)[-1] != "svg":
            raise ReviewError(f"{node_id}: edited figure root must be svg")
        if root.tag != SVG_ROOT:
            raise ReviewError(
                f"{node_id}: edited figure root must declare the standard SVG namespace"
            )
        if any(element.tag.rsplit("}", 1)[-1] == "script" for element in root.iter()):
            raise ReviewError(f"{node_id}: edited figure cannot contain script")
    return {**candidate, "svg": svg}


def validate_review(
    review: object,
    bundle: dict[str, object],
    *,
    known_nodes: set[str],
    allowed_decks: set[str],
    metis_root: Path | None = None,
) -> dict[str, object]:
    if not isinstance(review, dict):
        raise ReviewError("review must be a JSON object")
    missing_keys = REQUIRED_REVIEW_KEYS - set(review)
    if missing_keys:
        raise ReviewError(f"review is missing keys: {sorted(missing_keys)}")

    node_id = _require_string(review.get("node_id"), "node_id")
    if node_id != bundle.get("node_id"):
        raise ReviewError(f"{node_id}: review node does not match its bundle")
    _require_string(review.get("summary"), f"{node_id}.summary")

    sources = review.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ReviewError(f"{node_id}.sources needs at least one accuracy source")
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise ReviewError(f"{node_id}.sources[{index}] must be an object")
        _require_string(source.get("title"), f"{node_id}.sources[{index}].title")
        url = _require_string(source.get("url"), f"{node_id}.sources[{index}].url")
        if not (url.startswith("https://") or url.startswith("http://")):
            raise ReviewError(f"{node_id}.sources[{index}].url must be HTTP(S)")
        _require_string(
            source.get("published_or_updated"),
            f"{node_id}.sources[{index}].published_or_updated",
        )
        _require_string(source.get("accessed"), f"{node_id}.sources[{index}].accessed")
        supports = source.get("supports")
        if (
            not isinstance(supports, list)
            or not supports
            or not all(isinstance(claim, str) and claim.strip() for claim in supports)
        ):
            raise ReviewError(f"{node_id}.sources[{index}].supports must name claims")

    input_cards = bundle.get("cards")
    if not isinstance(input_cards, list):
        raise ReviewError(f"{node_id}: bundle cards must be a list")
    original_by_nid: dict[int, dict[str, object]] = {}
    expected_order: list[int] = []
    for index, card in enumerate(input_cards):
        label = f"{node_id}.bundle.cards[{index}]"
        if not isinstance(card, dict):
            raise ReviewError(f"{label} must be an object")
        nid = card.get("nid")
        if not isinstance(nid, int) or isinstance(nid, bool) or nid <= 0:
            raise ReviewError(f"{label}.nid must be a positive integer")
        if nid in original_by_nid:
            raise ReviewError(f"{node_id}: duplicate bundle nid {nid}")
        original_by_nid[nid] = card
        expected_order.append(nid)

    changes = review.get("card_changes")
    if not isinstance(changes, list):
        raise ReviewError(f"{node_id}.card_changes must be a list")
    actual_order = [change.get("nid") for change in changes if isinstance(change, dict)]
    if actual_order != expected_order:
        raise ReviewError(
            f"{node_id}: card coverage mismatch; expected {expected_order}, got {actual_order}"
        )

    normalized_changes: list[dict[str, object]] = []
    for index, change in enumerate(changes):
        label = f"{node_id}.card_changes[{index}]"
        if not isinstance(change, dict):
            raise ReviewError(f"{label} must be an object")
        nid = change.get("nid")
        if not isinstance(nid, int) or nid not in original_by_nid:
            raise ReviewError(f"{label}.nid is not an input card")
        action = change.get("action")
        if action not in VALID_ACTIONS:
            raise ReviewError(f"{label}.action must be one of {sorted(VALID_ACTIONS)}")
        _require_string(change.get("rationale"), f"{label}.rationale")
        score_before = change.get("score_before")
        score_after = change.get("score_after")
        if not isinstance(score_before, int) or not 1 <= score_before <= 5:
            raise ReviewError(f"{label}.score_before must be an integer from 1 to 5")
        if score_after not in (4, 5):
            raise ReviewError(f"{label}.score_after must be 4 or 5")
        raw_cards = change.get("cards")
        if not isinstance(raw_cards, list):
            raise ReviewError(f"{label}.cards must be a list")
        expected_lengths = {
            "keep": {1},
            "edit": {1},
            "split": set(range(2, 1000)),
            "delete": {0},
        }
        if len(raw_cards) not in expected_lengths[action]:
            raise ReviewError(
                f"{label}: action {action} is incompatible with {len(raw_cards)} cards"
            )
        cards = [
            _validate_card_payload(card, f"{label}.cards[{card_index}]")
            for card_index, card in enumerate(raw_cards)
        ]
        revision_kind = change.get("revision_kind")
        if action in {"edit", "split"}:
            if revision_kind not in VALID_REVISION_KINDS:
                raise ReviewError(
                    f"{label}.revision_kind must be wording or material"
                )
        elif revision_kind is not None:
            raise ReviewError(
                f"{label}.revision_kind is only valid for edit or split"
            )
        original = original_by_nid[nid]
        if action == "keep" and (
            cards[0]["front"] != original.get("front")
            or cards[0]["back"] != original.get("back")
        ):
            raise ReviewError(f"{label}: keep must preserve front and back exactly")
        normalized_changes.append({**change, "cards": cards})

    proposed_nodes = review.get("proposed_nodes")
    if not isinstance(proposed_nodes, list):
        raise ReviewError(f"{node_id}.proposed_nodes must be a list")
    proposed_ids: set[str] = set()
    for index, proposed in enumerate(proposed_nodes):
        label = f"{node_id}.proposed_nodes[{index}]"
        if not isinstance(proposed, dict):
            raise ReviewError(f"{label} must be an object")
        proposed_id = _require_string(proposed.get("node_id"), f"{label}.node_id")
        _primer_filename(proposed_id, f"{label}.node_id")
        if proposed_id in known_nodes or proposed_id in proposed_ids:
            raise ReviewError(
                f"{label}: proposed node id already exists or is duplicated"
            )
        proposed_ids.add(proposed_id)
        _require_string(proposed.get("title"), f"{label}.title")
        _require_string(proposed.get("module"), f"{label}.module")
        if proposed.get("difficulty") not in (1, 2, 3):
            raise ReviewError(f"{label}.difficulty must be 1, 2, or 3")
        primer_html = _require_string(
            proposed.get("primer_html"), f"{label}.primer_html"
        )
        _require_string(proposed.get("rationale"), f"{label}.rationale")
        _validate_primer_candidate(
            primer_html, node_id=proposed_id, metis_root=metis_root
        )

    node_moves = review.get("node_moves")
    if not isinstance(node_moves, list):
        raise ReviewError(f"{node_id}.node_moves must be a list")
    moved_nids: set[int] = set()
    for index, move in enumerate(node_moves):
        label = f"{node_id}.node_moves[{index}]"
        if not isinstance(move, dict):
            raise ReviewError(f"{label} must be an object")
        nid = move.get("nid")
        if not isinstance(nid, int) or nid not in original_by_nid or nid in moved_nids:
            raise ReviewError(
                f"{label}.nid is missing, duplicated, or outside the cluster"
            )
        moved_nids.add(nid)
        if move.get("from_node") != node_id:
            raise ReviewError(f"{label}.from_node must equal {node_id}")
        target = _require_string(move.get("to_node"), f"{label}.to_node")
        if target == "none" or target not in known_nodes | proposed_ids:
            raise ReviewError(
                f"{label}.to_node is not an existing or proposed real node"
            )
        _require_string(move.get("rationale"), f"{label}.rationale")
        matching_change = next(
            change for change in normalized_changes if change["nid"] == nid
        )
        if matching_change["action"] in ("split", "delete"):
            raise ReviewError(
                f"{label}: node moves require a kept or edited original card"
            )
    if node_id == "none":
        if any(change["action"] == "split" for change in normalized_changes):
            raise ReviewError(
                "none: placeholder cards must be kept/edited and moved, or deleted"
            )
        retained_placeholder_nids = {
            change["nid"]
            for change in normalized_changes
            if change["action"] in {"keep", "edit"}
        }
        if moved_nids != retained_placeholder_nids:
            raise ReviewError(
                "none: every retained placeholder card must have exactly one node move"
            )

    for change in normalized_changes:
        nid = change["nid"]
        original_nodes = {
            tag
            for tag in original_by_nid[nid].get("tags", [])
            if isinstance(tag, str) and tag.startswith("node::")
        }
        added_nodes = {
            tag
            for card in change["cards"]
            for tag in card["tags_add"]
            if tag.startswith("node::")
        }
        removed_nodes = {
            tag
            for card in change["cards"]
            for tag in card["tags_remove"]
            if tag.startswith("node::")
        }
        unknown_added_nodes = {
            tag for tag in added_nodes if tag[6:] not in known_nodes | proposed_ids
        }
        if unknown_added_nodes:
            raise ReviewError(
                f"{node_id}: nid {nid} adds unknown node tags "
                f"{sorted(unknown_added_nodes)}"
            )
        changes_concept = bool((added_nodes - original_nodes) or removed_nodes)
        if changes_concept and nid not in moved_nids:
            raise ReviewError(
                f"{node_id}: nid {nid} changes a concept tag and requires a node_moves record"
            )

    new_cards = review.get("new_cards")
    if not isinstance(new_cards, list):
        raise ReviewError(f"{node_id}.new_cards must be a list")
    normalized_adds: list[dict[str, object]] = []
    for index, addition in enumerate(new_cards):
        label = f"{node_id}.new_cards[{index}]"
        if not isinstance(addition, dict) or addition.get("action") != "add":
            raise ReviewError(f"{label}.action must be add")
        deck = addition.get("deck")
        if deck not in allowed_decks:
            raise ReviewError(f"{label}.deck is not an existing deck")
        _require_string(addition.get("rationale"), f"{label}.rationale")
        raw_cards = addition.get("cards")
        if not isinstance(raw_cards, list) or not raw_cards:
            raise ReviewError(f"{label}.cards must be a non-empty list")
        cards = [
            _validate_card_payload(card, f"{label}.cards[{card_index}]")
            for card_index, card in enumerate(raw_cards)
        ]
        for card_index, card in enumerate(cards):
            if card["tags_remove"]:
                raise ReviewError(
                    f"{label}.cards[{card_index}]: new cards cannot remove tags"
                )
            node_tags = [tag for tag in card["tags_add"] if tag.startswith("node::")]
            if (
                len(node_tags) != 1
                or node_tags[0][6:] not in known_nodes | proposed_ids
            ):
                raise ReviewError(
                    f"{label}.cards[{card_index}] needs one real node tag"
                )
        normalized_adds.append({**addition, "nid": None, "cards": cards})

    primer = review.get("primer")
    if not isinstance(primer, dict):
        raise ReviewError(f"{node_id}.primer must be an object")
    primer_action = primer.get("action")
    original_primer = bundle.get("primer_html")
    original_primer_path = bundle.get("primer_path")
    if original_primer is None:
        if (
            primer_action != "missing"
            or primer.get("html") is not None
            or primer.get("path") is not None
        ):
            raise ReviewError(
                f"{node_id}: cluster without a primer must use primer action missing"
            )
    elif primer.get("path") != original_primer_path:
        raise ReviewError(f"{node_id}: primer path must match the input bundle")
    elif primer_action == "keep":
        if primer.get("html") not in (None, original_primer):
            raise ReviewError(f"{node_id}: kept primer must be null or byte-identical")
    elif primer_action == "edit":
        html = _require_string(primer.get("html"), f"{node_id}.primer.html")
        _validate_primer_candidate(html, node_id=node_id, metis_root=metis_root)
    else:
        raise ReviewError(f"{node_id}: primer action must be keep or edit")
    _require_string(primer.get("rationale"), f"{node_id}.primer.rationale")

    unresolved = review.get("unresolved")
    if not isinstance(unresolved, list):
        raise ReviewError(f"{node_id}.unresolved must be a list")

    figure = _validate_figure(review, bundle, node_id=node_id)

    return {
        **review,
        "card_changes": normalized_changes,
        "new_cards": normalized_adds,
        "figure": figure,
    }


def compile_reviews(
    *,
    concept_manifest_path: Path,
    reviews_dir: Path,
    prep_job_dir: Path,
    output_dir: Path,
    require_complete: bool,
    revision_at: str | None = None,
    metis_root: Path | None = None,
    known_concept_manifest_path: Path | None = None,
) -> dict[str, object]:
    manifest = _load_json(concept_manifest_path)
    if not isinstance(manifest, list) or not manifest:
        raise ReviewError("concept manifest must be a non-empty list")
    node_rows: dict[str, dict[str, object]] = {}
    bundles: dict[str, dict[str, object]] = {}
    allowed_decks: set[str] = set()
    for index, row in enumerate(manifest):
        if not isinstance(row, dict):
            raise ReviewError(f"concept manifest row {index} must be an object")
        node_id = _require_string(row.get("node_id"), f"manifest[{index}].node_id")
        if node_id in node_rows:
            raise ReviewError(f"duplicate concept manifest node {node_id}")
        path = Path(_require_string(row.get("path"), f"manifest[{index}].path"))
        bundle = _load_json(path)
        if not isinstance(bundle, dict) or bundle.get("node_id") != node_id:
            raise ReviewError(f"{path}: bundle node mismatch")
        node_rows[node_id] = row
        bundles[node_id] = bundle
        decks = bundle.get("decks", [])
        if isinstance(decks, list):
            allowed_decks.update(str(deck) for deck in decks)

    known_nodes = set(node_rows)
    if known_concept_manifest_path is not None:
        known_manifest = _load_json(known_concept_manifest_path)
        if not isinstance(known_manifest, list):
            raise ReviewError("known concept manifest must be a list")
        for index, row in enumerate(known_manifest):
            if not isinstance(row, dict):
                raise ReviewError(
                    f"known concept manifest row {index} must be an object"
                )
            known_nodes.add(
                _require_string(row.get("node_id"), f"known_manifest[{index}].node_id")
            )

    missing_clusters = [
        node_id
        for node_id in node_rows
        if not (reviews_dir / f"{node_id}.json").is_file()
    ]
    if missing_clusters and require_complete:
        raise ReviewError(f"missing cluster reviews: {missing_clusters}")

    reviews: dict[str, dict[str, object]] = {}
    proposed_owner: dict[str, str] = {}
    for node_id, bundle in bundles.items():
        review_path = reviews_dir / f"{node_id}.json"
        if not review_path.is_file():
            continue
        review = validate_review(
            _load_json(review_path),
            bundle,
            known_nodes=known_nodes,
            allowed_decks=allowed_decks,
            metis_root=metis_root,
        )
        if require_complete and review["unresolved"]:
            raise ReviewError(f"{node_id}: unresolved findings remain")
        if require_complete and review["figure"]["action"] == "unreviewed":
            raise ReviewError(f"{node_id}: figure was not independently reviewed")
        for proposed in review["proposed_nodes"]:
            proposed_id = proposed["node_id"]
            if proposed_id in proposed_owner:
                raise ReviewError(
                    f"proposed node {proposed_id} appears in both "
                    f"{proposed_owner[proposed_id]} and {node_id}"
                )
            proposed_owner[proposed_id] = node_id
        reviews[node_id] = review

    if missing_clusters:
        return {
            "clusters": len(node_rows),
            "reviewed_clusters": len(reviews),
            "missing_clusters": missing_clusters,
            "reviewed_cards": sum(
                len(review["card_changes"]) for review in reviews.values()
            ),
            "unresolved_clusters": [
                node_id for node_id, review in reviews.items() if review["unresolved"]
            ],
        }

    decisions: dict[int, dict[str, object]] = {}
    additions: list[dict[str, object]] = []
    tag_mutations_by_nid: dict[int, dict[str, object]] = {}
    primer_changes: list[dict[str, object]] = []
    figure_changes: list[dict[str, object]] = []
    proposed_nodes: list[dict[str, object]] = []
    source_ledger: list[dict[str, object]] = []
    action_counts: Counter[str] = Counter()
    has_material_changes = False

    for node_id in node_rows:
        review = reviews[node_id]
        bundle = bundles[node_id]
        original_by_nid = {int(card["nid"]): card for card in bundle["cards"]}
        moves_by_nid = {move["nid"]: move for move in review["node_moves"]}
        for change in review["card_changes"]:
            nid = change["nid"]
            if nid in decisions:
                raise ReviewError(f"nid {nid} appears in more than one cluster")
            compiled_cards: list[dict[str, object]] = []
            for card_index, card in enumerate(change["cards"]):
                tags_add = list(card["tags_add"])
                tags_remove = list(card["tags_remove"])
                if card_index > 0:
                    tags_add = [
                        *original_by_nid[nid].get("tags", []),
                        *tags_add,
                    ]
                if nid in moves_by_nid:
                    move = moves_by_nid[nid]
                    tags_remove.append(f"node::{move['from_node']}")
                    tags_add.append(f"node::{move['to_node']}")
                tags_add = list(dict.fromkeys(tags_add))
                tags_remove = list(dict.fromkeys(tags_remove))
                if card_index > 0 and tags_remove:
                    raise ReviewError(
                        f"nid {nid}: split child cards cannot remove tags from the original"
                    )
                compiled_cards.append(
                    {"front": card["front"], "back": card["back"], "tags_add": tags_add}
                )
                if tags_remove:
                    mutation = tag_mutations_by_nid.setdefault(
                        nid,
                        {
                            "nid": nid,
                            "add": [],
                            "remove": [],
                            "expected_original_tags": original_by_nid[nid].get(
                                "tags", []
                            ),
                        },
                    )
                    mutation["add"] = list(dict.fromkeys([*mutation["add"], *tags_add]))
                    mutation["remove"] = list(
                        dict.fromkeys([*mutation["remove"], *tags_remove])
                    )
            apply_action = change["action"]
            if apply_action == "keep" and any(
                card["tags_add"] for card in compiled_cards
            ):
                # The trusted Anki writer deliberately ignores tag additions on
                # keep records. Preserve the semantic keep in the review summary,
                # but cross the apply boundary as a byte-identical edit so the
                # additions exist before the guarded removal/CAS phase.
                apply_action = "edit"
            revision_kind = (
                change.get("revision_kind")
                if change["action"] in {"edit", "split"}
                else "wording" if apply_action == "edit" else None
            )
            has_material_changes = (
                has_material_changes or revision_kind == "material"
            )
            decisions[nid] = {
                "nid": nid,
                "action": apply_action,
                "rationale": change["rationale"],
                "score_before": change["score_before"],
                "score_after": change["score_after"],
                "cards": compiled_cards,
            }
            if revision_kind is not None:
                decisions[nid]["revision_kind"] = revision_kind
            action_counts[change["action"]] += 1
        additions.extend(review["new_cards"])
        proposed_nodes.extend(review["proposed_nodes"])
        source_ledger.append({"node_id": node_id, "sources": review["sources"]})
        if review["primer"]["action"] == "edit":
            primer_changes.append(
                {
                    "node_id": node_id,
                    "path": review["primer"]["path"] or bundle.get("primer_path"),
                    "before": bundle.get("primer_html"),
                    "after": review["primer"]["html"],
                    "rationale": review["primer"]["rationale"],
                }
            )
        if review["figure"]["action"] == "edit":
            figure_path = Path(str(review["figure"]["path"]))
            if not figure_path.is_file():
                raise ReviewError(
                    f"{node_id}: original figure is missing: {figure_path}"
                )
            figure_changes.append(
                {
                    "node_id": node_id,
                    "path": str(figure_path),
                    "before": figure_path.read_text(encoding="utf-8"),
                    "after": review["figure"]["svg"],
                    "rationale": review["figure"]["rationale"],
                }
            )

    prep_manifest = _load_json(prep_job_dir / "manifest.json")
    expected_nids = (
        prep_manifest.get("nids") if isinstance(prep_manifest, dict) else None
    )
    if (
        not isinstance(expected_nids, list)
        or not all(
            isinstance(nid, int) and not isinstance(nid, bool) and nid > 0
            for nid in expected_nids
        )
        or len(expected_nids) != len(set(expected_nids))
        or set(expected_nids) != set(decisions)
    ):
        raise ReviewError(
            "compiled card decisions do not match the prepared Anki manifest"
        )

    batch_values = prep_manifest.get("batches")
    if not isinstance(batch_values, list):
        raise ReviewError("prepared Anki manifest batches must be a list")
    batch_names = [
        _batch_name(value, f"prepared Anki manifest batches[{index}]")
        for index, value in enumerate(batch_values)
    ]
    if len(batch_names) != len(set(batch_names)):
        raise ReviewError("prepared Anki manifest contains duplicate batch names")

    compiled_nids: list[int] = []
    prepared_outputs: list[tuple[str, list[dict[str, object]]]] = []
    for batch_name in batch_names:
        batch = _load_json(prep_job_dir / "in" / f"{batch_name}.json")
        cards = batch.get("cards") if isinstance(batch, dict) else None
        if not isinstance(cards, list):
            raise ReviewError(f"prepared batch {batch_name} has no card list")
        records = []
        for card in cards:
            nid = card.get("nid") if isinstance(card, dict) else None
            if nid not in decisions:
                raise ReviewError(
                    f"prepared batch {batch_name} references unknown nid {nid}"
                )
            compiled_nids.append(nid)
            records.append(decisions[nid])
        prepared_outputs.append((batch_name, records))
    if len(compiled_nids) != len(set(compiled_nids)) or set(compiled_nids) != set(
        expected_nids
    ):
        raise ReviewError(
            "compiled batches do not exactly cover the prepared Anki manifest"
        )

    if has_material_changes:
        if revision_at is None:
            raise ReviewError("material changes require --revision-at")
        try:
            parsed_revision = dt.datetime.strptime(revision_at, REVISION_AT_FORMAT)
        except ValueError as error:
            raise ReviewError(
                "revision_at must be canonical UTC YYYYMMDDTHHMMSSZ"
            ) from error
        if parsed_revision.strftime(REVISION_AT_FORMAT) != revision_at:
            raise ReviewError("revision_at must be canonical UTC YYYYMMDDTHHMMSSZ")
    elif revision_at is not None:
        raise ReviewError("revision_at is only valid when a material edit exists")

    if output_dir.exists() and any(output_dir.iterdir()):
        raise ReviewError(f"output directory is not empty: {output_dir}")
    verified_dir = output_dir / "verified"
    verified_dir.mkdir(parents=True, exist_ok=True)
    compiled_manifest = dict(prep_manifest)
    if revision_at is not None:
        compiled_manifest["revision_at"] = revision_at
    (output_dir / "manifest.json").write_text(
        json.dumps(compiled_manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    for batch_name, records in prepared_outputs:
        (verified_dir / f"{batch_name}.json").write_text(
            json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    if additions:
        (verified_dir / "batch_additions.json").write_text(
            json.dumps(additions, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    tag_mutations = list(tag_mutations_by_nid.values())
    artifacts = {
        "tag_mutations.json": tag_mutations,
        "primer_changes.json": primer_changes,
        "figure_changes.json": figure_changes,
        "proposed_nodes.json": proposed_nodes,
        "source_ledger.json": source_ledger,
    }
    for name, payload in artifacts.items():
        (output_dir / name).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    if primer_changes or proposed_nodes:
        primer_dir = output_dir / "primer_files"
        primer_dir.mkdir()
        for change in primer_changes:
            path = Path(str(change["path"]))
            filename = _primer_filename(path.name, f"{change['node_id']}.primer path")
            if path.suffix != ".html":
                raise ReviewError(f"{change['node_id']}: primer path must end in .html")
            destination = primer_dir / filename
            if destination.exists():
                raise ReviewError(f"duplicate primer output filename: {filename}")
            destination.write_text(str(change["after"]), encoding="utf-8")
        for proposed in proposed_nodes:
            filename = _primer_filename(
                str(proposed["node_id"]), f"{proposed['node_id']}.node_id"
            )
            destination = primer_dir / filename
            if destination.exists():
                raise ReviewError(f"duplicate primer output filename: {filename}")
            destination.write_text(str(proposed["primer_html"]), encoding="utf-8")
    if figure_changes:
        figure_dir = output_dir / "figure_files"
        figure_dir.mkdir()
        for change in figure_changes:
            path = Path(str(change["path"]))
            filename = path.name
            if path.suffix != ".svg" or not filename:
                raise ReviewError(
                    f"{change['node_id']}: figure path must name an SVG file"
                )
            destination = figure_dir / filename
            if destination.exists():
                raise ReviewError(f"duplicate figure output filename: {filename}")
            destination.write_text(str(change["after"]), encoding="utf-8")

    summary: dict[str, object] = {
        "clusters": len(node_rows),
        "reviewed_clusters": len(reviews),
        "missing_clusters": [],
        "existing_cards": len(decisions),
        "new_card_records": len(additions),
        "primer_edits": len(primer_changes),
        "figure_edits": len(figure_changes),
        "tag_mutations": len(tag_mutations),
        "proposed_nodes": len(proposed_nodes),
        "kept": action_counts["keep"],
        "edited": action_counts["edit"],
        "split": action_counts["split"],
        "deleted": action_counts["delete"],
    }
    (output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--concept-manifest", type=Path, required=True)
    parser.add_argument("--reviews-dir", type=Path, required=True)
    parser.add_argument("--prep-job-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--metis-root", type=Path)
    parser.add_argument(
        "--known-concept-manifest",
        type=Path,
        help="optional full catalog used to validate cross-cluster node moves",
    )
    parser.add_argument("--allow-incomplete", action="store_true")
    parser.add_argument(
        "--revision-at",
        help="UTC YYYYMMDDTHHMMSSZ publication time required by material edits",
    )
    args = parser.parse_args()
    try:
        summary = compile_reviews(
            concept_manifest_path=args.concept_manifest,
            reviews_dir=args.reviews_dir,
            prep_job_dir=args.prep_job_dir,
            output_dir=args.output_dir,
            require_complete=not args.allow_incomplete,
            revision_at=args.revision_at,
            metis_root=args.metis_root,
            known_concept_manifest_path=args.known_concept_manifest,
        )
    except ReviewError as error:
        parser.exit(1, f"semantic review rejected: {error}\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

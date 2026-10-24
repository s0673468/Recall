"""Read-only adapter for offline snapshots of Recall's existing local sources.

No credentials, environment files, network clients, defaults to live paths, or
raw-data output. The caller must select synthetic or explicitly opt into real data
before any source is opened. SQLite is an optional authoring snapshot, never a
replacement for Recall scheduling/review state.
"""
from __future__ import annotations

import json
import sqlite3
from collections import defaultdict
from pathlib import Path

from .features import NEGATIVE_REASONS, REASONS, QualityError, card_features, number

SOURCE_SCHEMA = 'recall.card-quality-source/v1'


def identifier(value):
    if type(value) is not int or not 0 < value <= 2**63 - 1:
        raise QualityError('expected a positive integer identifier')
    return value


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError, UnicodeError):
        raise QualityError('could not read valid local JSON') from None


def _rows(payload, name):
    rows = payload.get(name)
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise QualityError('source must contain notes, cards, review_log and note_flags arrays')
    return rows


def _anki_content(path):
    """Only front/back authoring fields from an explicitly supplied local copy."""
    try:
        connection = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)
        try:
            return {guid: (nid, str(flds or '').split('\x1f')) for nid, guid, flds in
                    connection.execute('SELECT id,guid,flds FROM notes')}
        finally:
            connection.close()
    except (OSError, sqlite3.Error):
        raise QualityError('could not read local Anki authoring snapshot') from None


def load_export(path, *, synthetic=False, real_data=False, anki_db=None):
    if synthetic == real_data:
        raise QualityError('choose --synthetic or explicit --real-data before reading a source')
    if anki_db is not None and not real_data:
        raise QualityError('Anki authoring snapshots require explicit --real-data')
    payload = read_json(path)
    if not isinstance(payload, dict) or payload.get('schema') != SOURCE_SCHEMA:
        raise QualityError('unsupported source schema')
    if synthetic and payload.get('synthetic') is not True:
        raise QualityError('synthetic mode requires a marked synthetic fixture')
    notes, cards = _rows(payload, 'notes'), _rows(payload, 'cards')
    reviews, flags = _rows(payload, 'review_log'), _rows(payload, 'note_flags')
    # Reject mixed-account snapshots without displaying or persisting account IDs.
    users = {row['user_id'] for rows in (notes, cards, reviews, flags) for row in rows if 'user_id' in row}
    if len(users) > 1:
        raise QualityError('mixed-account source is not supported')
    by_guid = {}
    for note in notes:
        guid = note.get('guid')
        if not isinstance(guid, str) or not guid or guid in by_guid:
            raise QualityError('missing or duplicate note identity')
        identifier(note.get('deck_id'))
        if not all(isinstance(note.get(field), str) for field in ('front', 'back')):
            raise QualityError('note shape fields must be text')
        by_guid[guid] = note
    by_id, card_guids = {}, set()
    for card in cards:
        cid, guid = identifier(card.get('id')), card.get('guid')
        if cid in by_id or guid in card_guids or guid not in by_guid:
            raise QualityError('duplicate card or missing note linkage')
        for name in ('reps', 'lapses', 'stability', 'difficulty'):
            number(card.get(name), maximum=10 if name == 'difficulty' else 1e12)
        by_id[cid] = card
        card_guids.add(guid)
    by_review, by_flag = defaultdict(list), defaultdict(set)
    for rows, target, is_review in ((reviews, by_review, True), (flags, by_flag, False)):
        for row in rows:
            cid = identifier(row.get('card_id'))
            if cid not in by_id or row.get('guid') != by_id[cid]['guid']:
                raise QualityError('review or flag has inconsistent card linkage')
            if is_review:
                if type(row.get('rating')) is not int or row['rating'] not in (1, 2, 3, 4):
                    raise QualityError('review rating must be between one and four')
                number(row.get('elapsed_ms'), maximum=86_400_000)
                target[cid].append({'rating': row['rating'], 'elapsed_ms': row.get('elapsed_ms')})
            else:
                reason, status = row.get('reason'), row.get('status', 'open')
                if reason not in REASONS or status not in {'open', 'resolved', 'dismissed'}:
                    raise QualityError('unsupported flag reason or status')
                # Resolved flags describe an older card version; exclude stale labels.
                if status == 'open':
                    target[cid].add(reason)
    authoring = _anki_content(anki_db) if anki_db is not None else None
    normalized = []
    for cid, card in sorted(by_id.items()):
        note = by_guid[card['guid']]
        if card.get('deleted') or note.get('deleted'):
            continue
        front, back = note['front'], note['back']
        nid = None
        if authoring is not None:
            local = authoring.get(card['guid'])
            if local is None:
                raise QualityError('card missing from local authoring snapshot')
            nid, fields = local
            identifier(nid)
            front = fields[0] if fields else ''
            back = fields[1] if len(fields) > 1 else ''
        reasons = by_flag[cid]
        liked = 'like' in reasons
        negative = bool(reasons & NEGATIVE_REASONS)
        # Conflicting feedback remains unlabelled, and likes remain protected.
        label = None if liked == negative else int(negative)
        normalized.append({
            **{name: card.get(name) for name in ('reps', 'lapses', 'difficulty', 'stability')},
            'card_id': cid, 'deck_id': note['deck_id'], 'front': front, 'back': back,
            'nid': nid,
            'reviews': by_review[cid], 'label': label,
            'label_reasons': sorted(reasons), 'liked': liked,
        })
    return card_features(normalized)

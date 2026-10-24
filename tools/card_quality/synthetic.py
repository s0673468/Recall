"""Repeatable invented decks with planted length/behaviour signals; no real data."""
from __future__ import annotations

import random
from .adapter import SOURCE_SCHEMA


def generate(seed=17, decks=4, cards_per_deck=30):
    rng = random.Random(seed)
    payload = dict(schema=SOURCE_SCHEMA, synthetic=True, notes=[], cards=[], review_log=[], note_flags=[])
    reasons = ('dislike', 'delete', 'wrong', 'confusing', 'too_long', 'duplicate')
    for deck in range(1, decks+1):
        for index in range(cards_per_deck):
            cid = (deck-1)*cards_per_deck + index + 1
            problem = index % 4 == 0  # Intentionally imbalanced.
            guid = f'synthetic-{cid}'
            front = 'Which invented symbol fits?'
            back = ' '.join(['imaginary'] * (rng.randint(60, 90) if problem else rng.randint(2, 7))) + '.'
            payload['notes'].append(dict(guid=guid, deck_id=deck, front=front, back=back))
            payload['cards'].append(dict(id=cid, guid=guid, reps=12, lapses=7 if problem else 0,
                                         difficulty=8+rng.random() if problem else 2+rng.random(),
                                         stability=1+rng.random() if problem else 40+rng.random()))
            for review in range(12):
                payload['review_log'].append(dict(card_id=cid, guid=guid,
                    rating=1 if problem and review < 8 else 3,
                    elapsed_ms=25000 if problem else 2000))
            payload['note_flags'].append(dict(card_id=cid, guid=guid, status='open',
                reason=reasons[(cid//4) % len(reasons)] if problem else 'like'))
    return payload

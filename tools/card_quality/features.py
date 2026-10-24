"""Fixed numeric shape/behaviour features. No vocabulary enters the model."""
from __future__ import annotations

import html
import math
import re
from collections import defaultdict
from html.parser import HTMLParser
from statistics import median

NEGATIVE_REASONS = frozenset({'dislike', 'delete', 'wrong', 'confusing', 'too_long', 'duplicate'})
REASONS = NEGATIVE_REASONS | {'like'}
FEATURE_NAMES = (
    'front_words', 'back_words', 'front_chars', 'back_chars', 'cloze_count',
    'has_list', 'has_table', 'has_math', 'has_image', 'front_back_ratio',
    'words_per_sentence', 'chars_per_word', 'sibling_similarity',
    'difficulty', 'stability', 'lapses', 'again_rate', 'answer_seconds',
    'missing_difficulty', 'missing_stability', 'missing_reviews', 'missing_timing',
)
# Each pair is a fixed description for a negative/positive model coefficient.
TRAITS = {
    'front_words': ('longer prompts', 'shorter prompts'),
    'back_words': ('longer answers', 'shorter answers'),
    'front_chars': ('more prompt characters', 'fewer prompt characters'),
    'back_chars': ('more answer characters', 'fewer answer characters'),
    'cloze_count': ('more cloze deletions', 'fewer cloze deletions'),
    'has_list': ('lists', 'no lists'), 'has_table': ('tables', 'no tables'),
    'has_math': ('math notation', 'no math notation'),
    'has_image': ('images', 'no images'),
    'front_back_ratio': ('more prompt text relative to the answer', 'less prompt text relative to the answer'),
    'words_per_sentence': ('longer sentences', 'shorter sentences'),
    'chars_per_word': ('longer words', 'shorter words'),
    'sibling_similarity': ('more similarity to cards in the same deck', 'less similarity to cards in the same deck'),
    'difficulty': ('higher FSRS difficulty', 'lower FSRS difficulty'),
    'stability': ('higher FSRS stability', 'lower FSRS stability'),
    'lapses': ('more lapses', 'fewer lapses'),
    'again_rate': ('higher Again rates', 'lower Again rates'),
    'answer_seconds': ('slower answers', 'faster answers'),
    'missing_difficulty': ('missing difficulty history', 'recorded difficulty history'),
    'missing_stability': ('missing stability history', 'recorded stability history'),
    'missing_reviews': ('missing review history', 'recorded review history'),
    'missing_timing': ('missing answer timing', 'recorded answer timing'),
}


class QualityError(ValueError):
    """Fixed, safe-to-display error; never include source values or paths."""


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in {'script', 'style', 'noscript', 'svg'}:
            self.hidden += 1
        elif tag in {'p', 'div', 'br', 'li', 'tr', 'td'}:
            self.parts.append(' ')

    def handle_endtag(self, tag):
        if tag in {'script', 'style', 'noscript', 'svg'} and self.hidden:
            self.hidden -= 1
        self.parts.append(' ')

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def visible(value):
    parser = _Text()
    parser.feed(value)
    return ' '.join(html.unescape(''.join(parser.parts)).split())


def number(value, *, maximum=1e12):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise QualityError('expected a nonnegative finite number')
    value = float(value)
    if not math.isfinite(value) or not 0 <= value <= maximum:
        raise QualityError('expected a nonnegative finite number within bounds')
    return value


def card_features(cards):
    """Extract all features in memory; similarity is max token Jaccard within deck.

    Tokens are transient, never hashed into model features or written to disk.
    An inverted index avoids comparisons with cards that share no tokens.
    """
    texts, tokens, indexes = [], [], defaultdict(lambda: defaultdict(set))
    for index, card in enumerate(cards):
        front, back = visible(card['front']), visible(card['back'])
        texts.append((front, back))
        words = set(re.findall(r'\w+', (front + ' ' + back).lower()))
        tokens.append(words)
        for word in words:
            indexes[card['deck_id']][word].add(index)
    results = []
    for index, card in enumerate(cards):
        front, back = texts[index]
        words = re.findall(r'\w+', front + ' ' + back)
        candidates = set()
        for word in tokens[index]:
            candidates.update(indexes[card['deck_id']][word])
        candidates.discard(index)
        similarity = max((len(tokens[index] & tokens[j]) / len(tokens[index] | tokens[j])
                          for j in candidates), default=0.0)
        raw = card['front'] + '\n' + card['back']
        reviews = card['reviews']
        timings = [r['elapsed_ms'] for r in reviews if r.get('elapsed_ms') is not None]
        difficulty = number(card.get('difficulty'), maximum=10)
        stability = number(card.get('stability'))
        lapses = number(card.get('lapses')) or 0.0
        again = sum(r['rating'] == 1 for r in reviews)
        metrics = {
            'front_words': len(re.findall(r'\w+', front)),
            'back_words': len(re.findall(r'\w+', back)),
            'front_chars': len(front), 'back_chars': len(back),
            'cloze_count': len(re.findall(r'\{\{c\d+::', raw, re.I)),
            'has_list': bool(re.search(r'<(?:ul|ol|li)\b|(?m:^\s*(?:[-*]|\d+[.)])\s)', raw, re.I)),
            'has_table': bool(re.search(r'<table\b|\|.+\|', raw, re.I)),
            'has_math': bool(re.search(r'\\[([]|\[latex\]|\$[^$]+\$', raw, re.I)),
            'has_image': bool(re.search(r'<img\b', raw, re.I)),
            'front_back_ratio': len(front) / max(1, len(back)),
            # Language-neutral readability proxies, not an English grade estimate.
            'words_per_sentence': len(words) / max(1, len(re.findall(r'[.!?]+', front + ' ' + back))),
            'chars_per_word': sum(map(len, words)) / max(1, len(words)),
            'sibling_similarity': similarity,
            'difficulty': difficulty or 0, 'stability': stability or 0,
            'lapses': lapses, 'again_rate': again / len(reviews) if reviews else 0,
            'answer_seconds': median(timings) / 1000 if timings else 0,
            'missing_difficulty': difficulty is None,
            'missing_stability': stability is None,
            'missing_reviews': not reviews, 'missing_timing': not timings,
        }
        results.append({
            'card_id': card['card_id'], 'deck_id': card['deck_id'],
            'x': [float(metrics[name]) for name in FEATURE_NAMES],
            'label': card['label'], 'label_reasons': card['label_reasons'],
            'liked': card['liked'], 'forget_score': forget_score(card),
            'nid': card.get('nid'),
        })
    return results


def forget_score(card):
    """Evidence-weighted heuristic, not an FSRS next-review probability."""
    evidence = []
    reviews = card['reviews']
    if reviews:
        evidence.append((0.4, (sum(r['rating'] == 1 for r in reviews) + 1) / (len(reviews) + 4)))
    reps = number(card.get('reps'))
    lapses = number(card.get('lapses'))
    if reps and lapses is not None:
        evidence.append((0.25, min(1, lapses / reps)))
    difficulty = number(card.get('difficulty'), maximum=10)
    if difficulty is not None and difficulty > 0:
        evidence.append((0.2, difficulty / 10))
    stability = number(card.get('stability'))
    if stability is not None and stability > 0:
        evidence.append((0.15, 1 / (1 + stability / 7)))
    return round(sum(w * v for w, v in evidence) / sum(w for w, _ in evidence), 6) if evidence else 0.25

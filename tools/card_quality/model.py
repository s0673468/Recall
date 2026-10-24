"""Deterministic L2 logistic regression with nested deck-held-out calibration."""
from __future__ import annotations

import math
from collections import Counter

from .features import FEATURE_NAMES, TRAITS, QualityError

MODEL_SCHEMA = 'recall.card-quality-model/v1'
ITERATIONS = 300
REGULARIZATION = 0.08


def sigmoid(value):
    value = max(-35, min(35, value))
    return 1 / (1 + math.exp(-value))


def _scale(x, means, scales):
    return [max(-6, min(6, (v - m) / s)) for v, m, s in zip(x, means, scales)]


def _fit(rows):
    labels = [r['label'] for r in rows]
    counts = Counter(labels)
    if set(counts) != {0, 1} or len(rows) < 4:
        raise QualityError('each training partition needs at least four labelled cards and both classes')
    size, width = len(rows), len(FEATURE_NAMES)
    means = [sum(r['x'][j] for r in rows) / size for j in range(width)]
    scales = [max(1e-8, math.sqrt(sum((r['x'][j] - means[j]) ** 2 for r in rows) / size))
              for j in range(width)]
    xs = [_scale(r['x'], means, scales) for r in rows]
    weights, intercept = [0.0] * width, 0.0
    balance = [size / (2 * counts[y]) for y in labels]
    for _ in range(ITERATIONS):
        gradients, bias = [0.0] * width, 0.0
        for x, y, b in zip(xs, labels, balance):
            error = b * (sigmoid(intercept + sum(w * v for w, v in zip(weights, x))) - y)
            bias += error
            for j, value in enumerate(x):
                gradients[j] += error * value
        intercept -= 0.15 * bias / size
        weights = [w - 0.15 * (g / size + REGULARIZATION * w) for w, g in zip(weights, gradients)]
    return dict(means=means, scales=scales, weights=weights, intercept=intercept)


def logit(model, row):
    return model['intercept'] + sum(w * v for w, v in zip(
        model['weights'], _scale(row['x'], model['means'], model['scales'])))


def _decks(rows):
    return sorted({r['deck_id'] for r in rows})


def _out_of_deck_logits(rows):
    if len(_decks(rows)) < 2:
        raise QualityError('calibration requires at least two labelled training decks')
    values = []
    for deck in _decks(rows):
        model = _fit([r for r in rows if r['deck_id'] != deck])
        values.extend((logit(model, r), r['label']) for r in rows if r['deck_id'] == deck)
    return values


def _calibrate(values):
    """Unweighted Platt calibration restores observed prevalence after balancing.

    Nonnegative slope preserves ordering. Only out-of-deck logits from training
    decks are used, including inside every outer evaluation fold.
    """
    prevalence = sum(y for _, y in values) / len(values)
    slope, intercept = 1.0, math.log(prevalence / (1 - prevalence))
    for _ in range(500):
        gs, gi = 0.0, 0.0
        for z, y in values:
            error = sigmoid(slope * z + intercept) - y
            gs += error * z
            gi += error
        slope = max(0.0, slope - 0.08 * (gs / len(values) + 0.01 * slope))
        intercept -= 0.08 * gi / len(values)
    return {'slope': slope, 'intercept': intercept}


def probability(model, row):
    calibration = model['calibration']
    return sigmoid(calibration['slope'] * logit(model, row) + calibration['intercept'])


def metrics(predictions):
    """Probabilities refer to problem/disliked (1), liked is the negative class."""
    n = len(predictions)
    brier = sum((p - y) ** 2 for p, y in predictions) / n
    loss = -sum(y * math.log(max(p, 1e-12)) + (1-y) * math.log(max(1-p, 1e-12))
                for p, y in predictions) / n
    ece = 0.0
    for bin_index in range(10):
        bucket = [(p, y) for p, y in predictions if min(9, int(p * 10)) == bin_index]
        if bucket:
            ece += abs(sum(p-y for p, y in bucket)) / n
    # Mann-Whitney rank AUC with ties, O(n log n).
    ordered = sorted(predictions)
    positives = sum(y for _, y in ordered)
    negatives = n - positives
    rank_sum, start = 0.0, 0
    while start < n:
        end = start + 1
        while end < n and ordered[end][0] == ordered[start][0]:
            end += 1
        rank_sum += ((start + 1 + end) / 2) * sum(y for _, y in ordered[start:end])
        start = end
    auc = ((rank_sum - positives * (positives + 1) / 2) / (positives * negatives)
           if positives and negatives else None)
    recalls = [sum(int(p >= 0.5) == y for p, y in predictions if y == label) /
               sum(y == label for _, y in predictions) for label in (0, 1)
               if any(y == label for _, y in predictions)]
    result = dict(cards=n, brier=brier, log_loss=loss, ece=ece, auc=auc,
                  balanced_accuracy=sum(recalls)/len(recalls))
    return {k: round(v, 6) if isinstance(v, float) else v for k, v in result.items()}


def train(rows):
    labelled = sorted((r for r in rows if r['label'] is not None), key=lambda r: r['card_id'])
    if len(_decks(labelled)) < 3:
        raise QualityError('nested leave-one-deck-out evaluation requires at least three labelled decks')
    predictions, baselines, folds = [], [], []
    for deck in _decks(labelled):
        training = [r for r in labelled if r['deck_id'] != deck]
        held_out = [r for r in labelled if r['deck_id'] == deck]
        model = _fit(training)
        model['calibration'] = _calibrate(_out_of_deck_logits(training))
        fold = [(probability(model, r), r['label']) for r in held_out]
        predictions.extend(fold)
        prior = sum(r['label'] for r in training) / len(training)
        baselines.extend((prior, r['label']) for r in held_out)
        folds.append(dict(index=len(folds) + 1, training_cards=len(training), **metrics(fold)))
    model = _fit(labelled)
    model['calibration'] = _calibrate(_out_of_deck_logits(labelled))
    counts = Counter(reason for row in labelled for reason in row['label_reasons'])
    model.update(
        schema=MODEL_SCHEMA, feature_names=list(FEATURE_NAMES),
        config=dict(iterations=ITERATIONS, regularization=REGULARIZATION, seed=0,
                    calibration='nested-deck-held-out-platt', class_weight='balanced'),
        evaluation=dict(method='nested-leave-one-deck-out', folds=folds,
                        aggregate=metrics(predictions), prevalence_baseline=metrics(baselines)),
        training=dict(labelled=len(labelled), unlabelled=len(rows)-len(labelled),
                      liked=sum(r['label'] == 0 for r in labelled),
                      problem=sum(r['label'] == 1 for r in labelled),
                      reasons={r: counts[r] for r in sorted(counts)}),
    )
    return model


def validate_model(model):
    if not isinstance(model, dict) or model.get('schema') != MODEL_SCHEMA or model.get('feature_names') != list(FEATURE_NAMES):
        raise QualityError('unsupported model schema or feature contract')
    for field in ('means', 'scales', 'weights'):
        values = model.get(field)
        if not isinstance(values, list) or len(values) != len(FEATURE_NAMES):
            raise QualityError('invalid model dimensions')
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in values):
            raise QualityError('model values must be finite numbers')
    if any(s <= 0 for s in model['scales']):
        raise QualityError('model scales must be positive')
    calibration = model.get('calibration')
    if not isinstance(calibration, dict):
        raise QualityError('invalid model calibration')
    for value in (model.get('intercept'), calibration.get('slope'), calibration.get('intercept')):
        if type(value) not in (int, float) or not math.isfinite(value):
            raise QualityError('model values must be finite numbers')
    if calibration['slope'] < 0:
        raise QualityError('invalid model calibration slope')
    # Never echo metadata supplied in a model file; explanations use fixed text.
    return model


def explain(model, limit=6):
    validate_model(model)
    ranked = sorted(zip(FEATURE_NAMES, model['weights']), key=lambda v: (-abs(v[1]), v[0]))
    if model['calibration']['slope'] <= 1e-8 or not any(abs(w) > 1e-6 for _, w in ranked):
        return ['No shared liked-card traits were learned.']
    return [f'Liked cards tend to have {TRAITS[name][0 if weight < 0 else 1]} '
            '(an association, not a cause).'
            for name, weight in ranked[:limit] if abs(weight) > 1e-6]


def score(model, rows):
    validate_model(model)
    output = []
    for row in sorted(rows, key=lambda r: r['card_id']):
        contributions = sorted(zip(FEATURE_NAMES, (w * v for w, v in zip(
            model['weights'], _scale(row['x'], model['means'], model['scales'])))),
            key=lambda pair: (-pair[1], pair[0]))
        reasons = [f'problem_association:{name}' for name, value in contributions if value > 1e-6][:3]
        # This fixed marker lets the gardener protect likes without raw flag rows.
        if row['liked']:
            reasons.insert(0, 'liked_keep_style')
        output.append(dict(card_id=row['card_id'], quality_score=round(1-probability(model, row), 6),
                           forget_score=row['forget_score'], top_reasons=reasons))
    return output

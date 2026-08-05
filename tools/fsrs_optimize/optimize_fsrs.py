#!/usr/bin/env python3
"""Fit Recall's personal FSRS-6 parameters without writing Supabase.

The live path is deliberately narrow: all Supabase requests are GETs, the
service key is accepted only from the process environment, and a user ID is
required to scope every table read.  The fitted parameters are never applied
to the database by this module.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import warnings
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from importlib import metadata
from numbers import Real
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence
import urllib.error
import urllib.parse
import urllib.request


MIN_HISTORY_REVIEWS = 1_000
MIN_EFFECTIVE_TRAIN_OBSERVATIONS = 512
HOLDOUT_FRACTION = 0.20
PAGE_SIZE = 1_000
HTTP_TIMEOUT_SECONDS = 30
EXPECTED_PY_FSRS_VERSION = "6.1.1"
DART_FSRS_VERSION = "2.0.1"
DEFAULT_DESIRED_RETENTION = 0.90
MIN_DESIRED_RETENTION = 0.70
MAX_DESIRED_RETENTION = 0.97
LOG_LOSS_EPSILON = 1e-9

# This is the exact order used by lib/features/review/application/fsrs_engine.dart
# through package fsrs 2.0.1.  Keep these values local so the compatibility
# gate does not trust the optimizer's defaults or silently adapt its output.
DART_DEFAULT_PARAMETERS: tuple[float, ...] = (
    0.2172,
    1.1771,
    3.2602,
    16.1507,
    7.0114,
    0.57,
    2.0966,
    0.0069,
    1.5261,
    0.112,
    1.0178,
    1.849,
    0.1133,
    0.3127,
    2.2934,
    0.2191,
    3.0004,
    0.7536,
    0.3332,
    0.1437,
    0.2,
)

DART_LOWER_BOUNDS: tuple[float, ...] = (
    0.001,
    0.001,
    0.001,
    0.001,
    1.0,
    0.001,
    0.001,
    0.001,
    0.0,
    0.0,
    0.001,
    0.001,
    0.001,
    0.001,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.1,
)

DART_UPPER_BOUNDS: tuple[float, ...] = (
    100.0,
    100.0,
    100.0,
    100.0,
    10.0,
    4.0,
    4.0,
    0.75,
    4.5,
    0.8,
    3.5,
    5.0,
    0.25,
    0.9,
    4.0,
    1.0,
    6.0,
    2.0,
    2.0,
    0.8,
    0.8,
)

# Fixed bins make reports comparable between runs.  The upper edge is treated
# as inclusive for the final bin; predictions are clamped before binning.
CALIBRATION_BIN_EDGES: tuple[float, ...] = (0.0, 0.60, 0.75, 0.85, 0.925, 1.0)


class CompatibilityError(ValueError):
    """The Python and Dart FSRS contracts cannot be proven compatible."""


class DataAccessError(RuntimeError):
    """A safe, value-free Supabase read failure."""


class InsufficientHistoryError(ValueError):
    """The review history is below the report-only optimizer floor."""


class RecommendationRefused(RuntimeError):
    """A candidate was evaluated but is not safe to recommend."""


@dataclass(frozen=True)
class Review:
    card_id: int
    rating: int
    rating_at: datetime
    row_id: int


@dataclass(frozen=True)
class CardSnapshot:
    card_id: int
    state: int | None
    stability: float | None
    difficulty: float | None
    last_review: datetime | None
    reps: int | None
    lapses: int | None


@dataclass(frozen=True)
class FsrsConfig:
    parameters: tuple[float, ...]
    desired_retention: float
    source: str

    def machine_json(self) -> dict[str, object]:
        return {
            "parameters": list(self.parameters),
            "desired_retention": self.desired_retention,
        }


@dataclass(frozen=True)
class CalibrationBin:
    lower: float
    upper: float
    count: int
    predicted: float
    observed: float

    def as_dict(self) -> dict[str, object]:
        return {
            "lower": self.lower,
            "upper": self.upper,
            "count": self.count,
            "predicted": self.predicted,
            "observed": self.observed,
        }


@dataclass(frozen=True)
class Evaluation:
    log_loss: float
    sample_count: int
    skipped_holdout_rows: int
    calibration: tuple[CalibrationBin, ...]
    calibration_mae: float

    def as_dict(self) -> dict[str, object]:
        return {
            "log_loss": self.log_loss,
            "sample_count": self.sample_count,
            "skipped_holdout_rows": self.skipped_holdout_rows,
            "calibration_mae": self.calibration_mae,
            "calibration": [item.as_dict() for item in self.calibration],
        }


@dataclass(frozen=True)
class Analysis:
    reviews: tuple[Review, ...]
    train_reviews: tuple[Review, ...]
    holdout_reviews: tuple[Review, ...]
    cards_read: int
    current: FsrsConfig
    fitted: FsrsConfig
    evaluations: dict[str, Evaluation]
    recommended: bool
    refusal_reason: str | None
    python_fsrs_version: str


def _is_number(value: object) -> bool:
    return isinstance(value, Real) and not isinstance(value, bool)


def validate_desired_retention(value: object, source: str) -> float:
    if not _is_number(value) or not math.isfinite(float(value)):
        raise CompatibilityError(
            f"{source} failed Recall desired-retention compatibility gate: "
            "expected a finite number"
        )
    retention = float(value)
    if not MIN_DESIRED_RETENTION <= retention <= MAX_DESIRED_RETENTION:
        raise CompatibilityError(
            f"{source} failed Recall desired-retention compatibility gate: "
            f"expected {MIN_DESIRED_RETENTION:.2f}..{MAX_DESIRED_RETENTION:.2f}, "
            f"got {retention}"
        )
    return retention


def validate_parameters(
    parameters: Sequence[object],
    source: str,
) -> tuple[float, ...]:
    """Validate the exact Dart FSRS-6 vector shape and bounds."""
    try:
        length = len(parameters)
    except TypeError as error:
        raise CompatibilityError(
            f"{source} failed Dart FSRS-{DART_FSRS_VERSION} compatibility gate: "
            "parameters must be a sequence"
        ) from error
    if length != len(DART_DEFAULT_PARAMETERS):
        raise CompatibilityError(
            f"{source} failed Dart FSRS-{DART_FSRS_VERSION} compatibility gate: "
            f"expected exactly {len(DART_DEFAULT_PARAMETERS)} parameters, got {length}"
        )

    validated: list[float] = []
    errors: list[str] = []
    for index, value in enumerate(parameters):
        if not _is_number(value) or not math.isfinite(float(value)):
            errors.append(f"parameters[{index}] is not a finite number")
            continue
        numeric = float(value)
        lower = DART_LOWER_BOUNDS[index]
        upper = DART_UPPER_BOUNDS[index]
        if numeric < lower or numeric > upper:
            errors.append(
                f"parameters[{index}] = {numeric} is out of bounds "
                f"[{lower}, {upper}]"
            )
        validated.append(numeric)
    if errors:
        raise CompatibilityError(
            f"{source} failed Dart FSRS-{DART_FSRS_VERSION} compatibility gate:\n"
            + "\n".join(errors)
        )
    return tuple(validated)


def verify_python_fsrs_contract() -> str:
    """Prove the pinned official Python package matches Recall's Dart contract."""
    try:
        package_version = metadata.version("fsrs")
        from fsrs.scheduler import (
            DEFAULT_PARAMETERS,
            LOWER_BOUNDS_PARAMETERS,
            UPPER_BOUNDS_PARAMETERS,
        )
    except (ImportError, metadata.PackageNotFoundError) as error:
        raise CompatibilityError(
            'The official fsrs optimizer is unavailable; install '
            'tools/fsrs_optimize/requirements.txt'
        ) from error

    if package_version != EXPECTED_PY_FSRS_VERSION:
        raise CompatibilityError(
            "Python FSRS compatibility gate failed: expected official "
            f"fsrs {EXPECTED_PY_FSRS_VERSION}, got {package_version}"
        )
    if tuple(float(value) for value in DEFAULT_PARAMETERS) != DART_DEFAULT_PARAMETERS:
        raise CompatibilityError(
            "Python FSRS compatibility gate failed: package defaults differ "
            "from Dart fsrs 2.0.1; no parameter adaptation is allowed"
        )
    if tuple(float(value) for value in LOWER_BOUNDS_PARAMETERS) != DART_LOWER_BOUNDS:
        raise CompatibilityError(
            "Python FSRS compatibility gate failed: lower bounds differ "
            "from Dart fsrs 2.0.1; no parameter adaptation is allowed"
        )
    if tuple(float(value) for value in UPPER_BOUNDS_PARAMETERS) != DART_UPPER_BOUNDS:
        raise CompatibilityError(
            "Python FSRS compatibility gate failed: upper bounds differ "
            "from Dart fsrs 2.0.1; no parameter adaptation is allowed"
        )
    return package_version


def _parse_utc(value: object, source: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{source} must be an ISO-8601 timestamp")
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ValueError(f"{source} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError(f"{source} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _parse_int(value: object, source: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{source} must be an integer")
    return value


def parse_review_rows(rows: Iterable[Mapping[str, object]], source: str) -> tuple[Review, ...]:
    parsed: list[Review] = []
    for index, row in enumerate(rows):
        if not isinstance(row, Mapping):
            raise ValueError(f"{source} row {index} must be an object")
        card_id = _parse_int(row.get("card_id"), f"{source} row {index} card_id")
        rating = _parse_int(row.get("rating"), f"{source} row {index} rating")
        if rating not in (1, 2, 3, 4):
            raise ValueError(f"{source} row {index} rating must be 1, 2, 3, or 4")
        row_id_value = row.get("id", index)
        row_id = _parse_int(row_id_value, f"{source} row {index} id")
        parsed.append(
            Review(
                card_id=card_id,
                rating=rating,
                rating_at=_parse_utc(
                    row.get("rating_at"),
                    f"{source} row {index} rating_at",
                ),
                row_id=row_id,
            )
        )
    return tuple(sorted(parsed, key=lambda item: (item.rating_at, item.row_id)))


def _parse_optional_float(value: object, source: str) -> float | None:
    if value is None:
        return None
    if not _is_number(value) or not math.isfinite(float(value)):
        raise ValueError(f"{source} must be a finite number or null")
    return float(value)


def parse_card_rows(
    rows: Iterable[Mapping[str, object]],
    source: str,
) -> tuple[CardSnapshot, ...]:
    cards: list[CardSnapshot] = []
    for index, row in enumerate(rows):
        if not isinstance(row, Mapping):
            raise ValueError(f"{source} row {index} must be an object")
        card_id = _parse_int(row.get("id"), f"{source} row {index} id")
        state_value = row.get("state")
        state = None if state_value is None else _parse_int(
            state_value,
            f"{source} row {index} state",
        )
        reps_value = row.get("reps")
        lapses_value = row.get("lapses")
        cards.append(
            CardSnapshot(
                card_id=card_id,
                state=state,
                stability=_parse_optional_float(
                    row.get("stability"),
                    f"{source} row {index} stability",
                ),
                difficulty=_parse_optional_float(
                    row.get("difficulty"),
                    f"{source} row {index} difficulty",
                ),
                last_review=(
                    None
                    if row.get("last_review") is None
                    else _parse_utc(
                        row.get("last_review"),
                        f"{source} row {index} last_review",
                    )
                ),
                reps=(
                    None
                    if reps_value is None
                    else _parse_int(reps_value, f"{source} row {index} reps")
                ),
                lapses=(
                    None
                    if lapses_value is None
                    else _parse_int(lapses_value, f"{source} row {index} lapses")
                ),
            )
        )
    return tuple(cards)


def _settings_value(raw: object, source: str) -> Mapping[str, object]:
    value = raw
    if isinstance(raw, Mapping) and "settings_value" in raw:
        value = raw["settings_value"]
    if not isinstance(value, Mapping):
        raise CompatibilityError(f"{source} settings_value must be an object")
    return value


def parse_fsrs_config(raw: object, source: str) -> FsrsConfig | None:
    if raw is None:
        return None
    value = _settings_value(raw, source)
    parameters = value.get("parameters", value.get("weights"))
    if not isinstance(parameters, Sequence) or isinstance(parameters, (str, bytes)):
        raise CompatibilityError(
            f"{source} failed Dart FSRS-{DART_FSRS_VERSION} compatibility gate: "
            "parameters must be a sequence"
        )
    validated = validate_parameters(parameters, source)
    retention_value = value.get(
        "desired_retention",
        value.get("desiredRetention", value.get("requestRetention", DEFAULT_DESIRED_RETENTION)),
    )
    retention = validate_desired_retention(retention_value, source)
    return FsrsConfig(validated, retention, source)


def parse_effective_retention(raw: object, fallback: float, source: str) -> float:
    """Mirror RecallPrefs.fromJson's retention clamp for the live config."""
    if raw is None:
        return fallback
    value = _settings_value(raw, source)
    retention = value.get("desired_retention")
    if not _is_number(retention) or not math.isfinite(float(retention)):
        return fallback
    return min(MAX_DESIRED_RETENTION, max(MIN_DESIRED_RETENTION, float(retention)))


def chronological_split(
    reviews: Sequence[Review],
) -> tuple[tuple[Review, ...], tuple[Review, ...]]:
    ordered = tuple(sorted(reviews, key=lambda item: (item.rating_at, item.row_id)))
    if len(ordered) < MIN_HISTORY_REVIEWS:
        raise InsufficientHistoryError(
            f"DIR-1a requires at least {MIN_HISTORY_REVIEWS} reviews; "
            f"received {len(ordered)}"
        )
    holdout_count = max(1, math.ceil(len(ordered) * HOLDOUT_FRACTION))
    split_index = len(ordered) - holdout_count
    return ordered[:split_index], ordered[split_index:]


def count_elapsed_observations(reviews: Sequence[Review]) -> int:
    """Count the non-first, full-day observations used by py-fsrs."""
    last_review: dict[int, datetime] = {}
    count = 0
    for review in sorted(reviews, key=lambda item: (item.rating_at, item.row_id)):
        previous = last_review.get(review.card_id)
        if previous is not None and (review.rating_at - previous).days > 0:
            count += 1
        last_review[review.card_id] = review.rating_at
    return count


def _to_fsrs_review_logs(reviews: Sequence[Review]) -> list[Any]:
    try:
        from fsrs import Rating, ReviewLog
    except ImportError as error:
        raise CompatibilityError(
            'The official fsrs optimizer is unavailable; install '
            'tools/fsrs_optimize/requirements.txt'
        ) from error
    return [
        ReviewLog(
            card_id=review.card_id,
            rating=Rating(review.rating),
            review_datetime=review.rating_at,
            review_duration=None,
        )
        for review in reviews
    ]


def fit_parameters(train_reviews: Sequence[Review]) -> tuple[float, ...]:
    """Fit with the official optimizer, then apply the Dart compatibility gate."""
    verify_python_fsrs_contract()
    effective_observations = count_elapsed_observations(train_reviews)
    if effective_observations < MIN_EFFECTIVE_TRAIN_OBSERVATIONS:
        raise InsufficientHistoryError(
            "DIR-1a requires at least "
            f"{MIN_EFFECTIVE_TRAIN_OBSERVATIONS} elapsed training observations; "
            f"received {effective_observations}"
        )
    try:
        from fsrs import Optimizer
    except ImportError as error:
        raise CompatibilityError(
            'The official fsrs optimizer is unavailable; install '
            'tools/fsrs_optimize/requirements.txt'
        ) from error

    # py-fsrs uses a fixed Python RNG seed for card ordering.  Seed torch too
    # so dependency updates cannot turn a deterministic fixture into a moving
    # test result without changing the observed output.
    try:
        import torch

        torch.manual_seed(42)
    except ImportError as error:
        raise CompatibilityError(
            'The official fsrs optimizer requires torch; install '
            'tools/fsrs_optimize/requirements.txt'
        ) from error

    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="Converting a tensor with requires_grad=True to a scalar",
        )
        output = Optimizer(_to_fsrs_review_logs(train_reviews)).compute_optimal_parameters(
            verbose=False
        )
    return validate_parameters(output, "optimizer output")


def _make_scheduler(parameters: Sequence[float], desired_retention: float) -> Any:
    from fsrs import Scheduler

    return Scheduler(
        parameters=tuple(parameters),
        desired_retention=desired_retention,
        learning_steps=(timedelta(minutes=1), timedelta(minutes=10)),
        relearning_steps=(timedelta(minutes=10),),
        enable_fuzzing=False,
    )


def _calibration_bins(predictions: Sequence[tuple[float, int]]) -> tuple[CalibrationBin, ...]:
    bins: list[CalibrationBin] = []
    for index, lower in enumerate(CALIBRATION_BIN_EDGES[:-1]):
        upper = CALIBRATION_BIN_EDGES[index + 1]
        values = [
            (prediction, observed)
            for prediction, observed in predictions
            if (lower <= prediction < upper)
            or (index == len(CALIBRATION_BIN_EDGES) - 2 and prediction == upper)
        ]
        if values:
            predicted = sum(item[0] for item in values) / len(values)
            observed = sum(item[1] for item in values) / len(values)
        else:
            predicted = 0.0
            observed = 0.0
        bins.append(
            CalibrationBin(
                lower=lower,
                upper=upper,
                count=len(values),
                predicted=predicted,
                observed=observed,
            )
        )
    return tuple(bins)


def evaluate_holdout(
    reviews: Sequence[Review],
    train_count: int,
    parameters: Sequence[float],
    desired_retention: float,
) -> Evaluation:
    """Replay all known history and score only the chronological holdout."""
    validate_parameters(parameters, "evaluation parameters")
    validate_desired_retention(desired_retention, "evaluation desired_retention")
    from fsrs import Card, Rating

    scheduler = _make_scheduler(parameters, desired_retention)
    cards: dict[int, Any] = {}
    predictions: list[tuple[float, int]] = []
    skipped = 0
    for index, review in enumerate(reviews):
        card = cards.get(review.card_id)
        if card is None:
            card = Card(card_id=review.card_id, due=review.rating_at)
        eligible = (
            index >= train_count
            and card.last_review is not None
            and (review.rating_at - card.last_review).days > 0
        )
        if eligible:
            probability = float(
                scheduler.get_card_retrievability(
                    card=card,
                    current_datetime=review.rating_at,
                )
            )
            probability = min(1.0 - 1e-12, max(1e-12, probability))
            observed = 0 if review.rating == 1 else 1
            predictions.append((probability, observed))
        elif index >= train_count:
            skipped += 1
        card, _ = scheduler.review_card(
            card=card,
            rating=Rating(review.rating),
            review_datetime=review.rating_at,
            review_duration=None,
        )
        cards[review.card_id] = card

    if not predictions:
        raise ValueError("the holdout has no elapsed review-state observations to score")
    log_loss = sum(
        -(
            observed * math.log(probability)
            + (1 - observed) * math.log(1.0 - probability)
        )
        for probability, observed in predictions
    ) / len(predictions)
    bins = _calibration_bins(predictions)
    calibration_mae = (
        sum(
            abs(item.predicted - item.observed) * item.count
            for item in bins
            if item.count
        )
        / len(predictions)
    )
    return Evaluation(
        log_loss=log_loss,
        sample_count=len(predictions),
        skipped_holdout_rows=skipped,
        calibration=bins,
        calibration_mae=calibration_mae,
    )


def analyze(
    reviews: Sequence[Review],
    *,
    cards_read: int,
    current_config: FsrsConfig | None,
    effective_retention: float | None = None,
    fit_function: Callable[[Sequence[Review]], Sequence[float]] = fit_parameters,
    evaluate_function: Callable[
        [Sequence[Review], int, Sequence[float], float], Evaluation
    ] = evaluate_holdout,
) -> Analysis:
    python_version = verify_python_fsrs_contract()
    ordered = tuple(sorted(reviews, key=lambda item: (item.rating_at, item.row_id)))
    train, holdout = chronological_split(ordered)
    effective_observations = count_elapsed_observations(train)
    if effective_observations < MIN_EFFECTIVE_TRAIN_OBSERVATIONS:
        raise InsufficientHistoryError(
            "DIR-1a requires at least "
            f"{MIN_EFFECTIVE_TRAIN_OBSERVATIONS} elapsed training observations; "
            f"received {effective_observations}"
        )
    retention = effective_retention
    if retention is None:
        retention = current_config.desired_retention if current_config else DEFAULT_DESIRED_RETENTION
    retention = validate_desired_retention(retention, "effective desired_retention")

    current_parameters = (
        current_config.parameters if current_config else DART_DEFAULT_PARAMETERS
    )
    current = FsrsConfig(
        parameters=validate_parameters(current_parameters, "current configuration"),
        desired_retention=retention,
        source=current_config.source if current_config else "current configuration (package defaults)",
    )
    fitted_parameters = validate_parameters(fit_function(train), "optimizer output")
    fitted = FsrsConfig(fitted_parameters, retention, "new fit")
    train_count = len(train)
    evaluations = {
        "package_defaults": evaluate_function(
            ordered,
            train_count,
            DART_DEFAULT_PARAMETERS,
            retention,
        ),
        "current": evaluate_function(
            ordered,
            train_count,
            current.parameters,
            retention,
        ),
        "new_fit": evaluate_function(
            ordered,
            train_count,
            fitted.parameters,
            retention,
        ),
    }
    new_loss = evaluations["new_fit"].log_loss
    current_loss = evaluations["current"].log_loss
    recommended = new_loss < current_loss - LOG_LOSS_EPSILON
    refusal_reason = None
    if not recommended:
        refusal_reason = (
            "new fit was not recommended because its holdout log-loss "
            f"({new_loss:.6f}) did not beat current "
            f"({current_loss:.6f})"
        )
    return Analysis(
        reviews=ordered,
        train_reviews=train,
        holdout_reviews=holdout,
        cards_read=cards_read,
        current=current,
        fitted=fitted,
        evaluations=evaluations,
        recommended=recommended,
        refusal_reason=refusal_reason,
        python_fsrs_version=python_version,
    )


def _format_calibration(evaluation: Evaluation) -> list[str]:
    lines = []
    for item in evaluation.calibration:
        if item.count == 0:
            continue
        lines.append(
            f"    [{item.lower:.3f}, {item.upper:.3f}]: n={item.count}, "
            f"predicted={item.predicted:.3f}, observed={item.observed:.3f}"
        )
    return lines or ["    no populated bins"]


def render_report(analysis: Analysis) -> str:
    status = "RECOMMENDED" if analysis.recommended else "REFUSED"
    lines = [
        "Recall DIR-1a personal FSRS-6 optimizer",
        "==========================================",
        f"Status: {status}",
        (
            f"History: {len(analysis.reviews)} reviews; "
            f"train={len(analysis.train_reviews)}; "
            f"holdout={len(analysis.holdout_reviews)}; "
            f"current cards read={analysis.cards_read}"
        ),
        (
            f"Compatibility: Dart fsrs {DART_FSRS_VERSION}; "
            f"Python fsrs {analysis.python_fsrs_version}; "
            f"parameters=21; desired_retention={analysis.fitted.desired_retention:.3f}"
        ),
        "",
        "Holdout evaluation (lower log-loss is better):",
    ]
    for name, label in (
        ("package_defaults", "Package defaults"),
        ("current", "Current configuration"),
        ("new_fit", "New fit"),
    ):
        evaluation = analysis.evaluations[name]
        lines.append(
            f"  {label}: log_loss={evaluation.log_loss:.6f}; "
            f"samples={evaluation.sample_count}; "
            f"calibration_mae={evaluation.calibration_mae:.6f}; "
            f"skipped={evaluation.skipped_holdout_rows}"
        )
        lines.extend(_format_calibration(evaluation))
    lines.extend(["", "Recommendation:"])
    if analysis.recommended:
        lines.append(
            "  New fit beats the current configuration on chronological holdout "
            "log-loss. The JSON candidate is safe to review manually."
        )
    else:
        lines.append(f"  {analysis.refusal_reason}.")
        lines.append("  No machine-readable candidate should be applied.")
    lines.extend(
        [
            "",
            "This tool is report-only. No Supabase write or scheduling change was performed.",
        ]
    )
    return "\n".join(lines) + "\n"


def _fixture_payload(path: Path) -> tuple[tuple[Review, ...], tuple[CardSnapshot, ...], object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DataAccessError(f"could not read fixture {path}") from error
    if isinstance(payload, list):
        return parse_review_rows(payload, str(path)), (), None
    if not isinstance(payload, Mapping):
        raise ValueError(f"fixture {path} must be an object or review array")
    raw_reviews = payload.get("review_log", payload.get("reviews"))
    if not isinstance(raw_reviews, list):
        raise ValueError(f"fixture {path} must contain a review_log array")
    raw_cards = payload.get("cards", [])
    if not isinstance(raw_cards, list):
        raise ValueError(f"fixture {path} cards must be an array")
    return (
        parse_review_rows(raw_reviews, str(path)),
        parse_card_rows(raw_cards, str(path)),
        payload.get("fsrs_params"),
    )


def _read_json(
    base_url: str,
    service_key: str,
    table: str,
    params: Mapping[str, str],
) -> object:
    endpoint = f"{base_url.rstrip('/')}/rest/v1/{table}"
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(
        f"{endpoint}?{query}",
        headers={
            "Accept": "application/json",
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raise DataAccessError(
            f"Supabase read of {table} failed with HTTP {error.code}"
        ) from error
    except urllib.error.URLError as error:
        raise DataAccessError(f"Supabase read of {table} failed at transport") from error
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise DataAccessError(f"Supabase read of {table} returned invalid JSON") from error


class SupabaseReadClient:
    """GET-only Supabase client for a single explicit user."""

    def __init__(self, base_url: str, service_key: str, user_id: str) -> None:
        if not base_url.strip() or not service_key.strip() or not user_id.strip():
            raise ValueError("SUPABASE_URL, SUPABASE_SERVICE_KEY, and user ID are required")
        self._base_url = base_url
        self._service_key = service_key
        self._user_id = user_id

    def _page(self, table: str, select: str, order: str | None = None) -> list[Mapping[str, object]]:
        rows: list[Mapping[str, object]] = []
        offset = 0
        while True:
            params = {
                "select": select,
                "user_id": f"eq.{self._user_id}",
                "limit": str(PAGE_SIZE),
                "offset": str(offset),
            }
            if order:
                params["order"] = order
            payload = _read_json(
                self._base_url,
                self._service_key,
                table,
                params,
            )
            if not isinstance(payload, list) or any(
                not isinstance(item, Mapping) for item in payload
            ):
                raise DataAccessError(f"Supabase read of {table} returned an invalid page")
            page = [dict(item) for item in payload]
            rows.extend(page)
            if len(page) < PAGE_SIZE:
                return rows
            offset += PAGE_SIZE

    def fetch_reviews(self) -> tuple[Review, ...]:
        rows = self._page(
            "review_log",
            "id,card_id,rating_at,rating",
            order="rating_at.asc,id.asc",
        )
        return parse_review_rows(rows, "Supabase review_log")

    def fetch_cards(self) -> tuple[CardSnapshot, ...]:
        rows = self._page(
            "cards",
            "id,state,stability,difficulty,last_review,reps,lapses",
            order="id.asc",
        )
        return parse_card_rows(rows, "Supabase cards")

    def fetch_setting(self, key: str) -> object | None:
        payload = _read_json(
            self._base_url,
            self._service_key,
            "user_settings",
            {
                "select": "settings_value",
                "user_id": f"eq.{self._user_id}",
                "settings_key": f"eq.{key}",
                "limit": "2",
            },
        )
        if not isinstance(payload, list) or any(
            not isinstance(item, Mapping) for item in payload
        ):
            raise DataAccessError("Supabase user_settings returned an invalid response")
        if not payload:
            return None
        if len(payload) > 1:
            raise DataAccessError(f"Supabase user_settings has duplicate {key} rows")
        return payload[0].get("settings_value")


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixture",
        type=Path,
        help="read synthetic rows from JSON instead of Supabase",
    )
    parser.add_argument(
        "--user-id",
        help="Supabase user UUID; otherwise RECALL_USER_ID is required",
    )
    parser.add_argument("--report-output", type=Path)
    parser.add_argument("--json-output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.fixture:
            reviews, cards, raw_fsrs = _fixture_payload(args.fixture)
            raw_prefs = None
            payload = json.loads(args.fixture.read_text(encoding="utf-8"))
            if isinstance(payload, Mapping):
                raw_prefs = payload.get("recall_prefs")
            current_config = parse_fsrs_config(raw_fsrs, "fixture fsrs_params")
            effective_retention = parse_effective_retention(
                raw_prefs,
                current_config.desired_retention
                if current_config
                else DEFAULT_DESIRED_RETENTION,
                "fixture recall_prefs",
            )
        else:
            user_id = args.user_id or os.environ.get("RECALL_USER_ID")
            base_url = os.environ.get("SUPABASE_URL")
            service_key = os.environ.get("SUPABASE_SERVICE_KEY")
            if not base_url or not service_key or not user_id:
                raise DataAccessError(
                    "live mode requires SUPABASE_URL, SUPABASE_SERVICE_KEY, and "
                    "RECALL_USER_ID or --user-id"
                )
            client = SupabaseReadClient(base_url, service_key, user_id)
            reviews = client.fetch_reviews()
            cards = client.fetch_cards()
            raw_fsrs = client.fetch_setting("fsrs_params")
            raw_prefs = client.fetch_setting("recall_prefs")
            current_config = parse_fsrs_config(raw_fsrs, "Supabase fsrs_params")
            effective_retention = parse_effective_retention(
                raw_prefs,
                current_config.desired_retention
                if current_config
                else DEFAULT_DESIRED_RETENTION,
                "Supabase recall_prefs",
            )
        analysis = analyze(
            reviews,
            cards_read=len(cards),
            current_config=current_config,
            effective_retention=effective_retention,
        )
        report = render_report(analysis)
        if args.report_output:
            _write_text(args.report_output, report)
        else:
            print(report, end="")
        if analysis.recommended:
            if args.json_output:
                _write_text(
                    args.json_output,
                    json.dumps(analysis.fitted.machine_json(), indent=2) + "\n",
                )
            elif not args.report_output:
                print(json.dumps(analysis.fitted.machine_json(), indent=2))
        elif args.json_output:
            print("JSON candidate not written because the recommendation was refused.")
        return 0 if analysis.recommended else 2
    except (CompatibilityError, DataAccessError, InsufficientHistoryError, ValueError) as error:
        message = f"DIR-1a refused: {error}"
        if args.report_output:
            _write_text(args.report_output, message + "\n")
        else:
            print(message)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

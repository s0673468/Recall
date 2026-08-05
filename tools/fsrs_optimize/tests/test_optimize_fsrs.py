from __future__ import annotations

import json
import math
import random
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import optimize_fsrs as optimize


FIXTURE = Path(__file__).parent / "fixtures" / "report_fixture.json"


def _reviews(count: int) -> tuple[optimize.Review, ...]:
    start = datetime(2021, 1, 1, tzinfo=timezone.utc)
    return tuple(
        optimize.Review(
            card_id=(index % 40) + 1,
            rating=1 if index % 11 == 0 else 3,
            rating_at=start + timedelta(days=index),
            row_id=index,
        )
        for index in range(count)
    )


def _evaluation(log_loss: float) -> optimize.Evaluation:
    return optimize.Evaluation(
        log_loss=log_loss,
        sample_count=200,
        skipped_holdout_rows=0,
        calibration=(),
        calibration_mae=0.01,
    )


def _candidate_parameters() -> tuple[float, ...]:
    values = list(optimize.DART_DEFAULT_PARAMETERS)
    values[0] += 0.01
    return tuple(values)


class ContractTests(unittest.TestCase):
    def test_python_package_contract_matches_dart(self) -> None:
        self.assertEqual(
            optimize.verify_python_fsrs_contract(),
            optimize.EXPECTED_PY_FSRS_VERSION,
        )

    def test_invalid_19_vector_is_rejected_loudly(self) -> None:
        with self.assertRaisesRegex(
            optimize.CompatibilityError,
            r"expected exactly 21 parameters, got 19",
        ):
            optimize.validate_parameters(
                optimize.DART_DEFAULT_PARAMETERS[:-2],
                "test 19-vector",
            )

    def test_history_below_floor_is_refused(self) -> None:
        with self.assertRaisesRegex(
            optimize.InsufficientHistoryError,
            r"requires at least 1000 reviews; received 999",
        ):
            optimize.chronological_split(_reviews(999))


class SplitAndRecommendationTests(unittest.TestCase):
    def test_last_20_percent_is_chronological_holdout(self) -> None:
        train, holdout = optimize.chronological_split(_reviews(1000))
        self.assertEqual(len(train), 800)
        self.assertEqual(len(holdout), 200)
        self.assertLess(train[-1].rating_at, holdout[0].rating_at)
        self.assertEqual(holdout[0].row_id, 800)
        self.assertEqual(holdout[-1].row_id, 999)

    def test_worse_fit_is_refused(self) -> None:
        current = optimize.FsrsConfig(
            parameters=optimize.DART_DEFAULT_PARAMETERS,
            desired_retention=0.9,
            source="current fsrs_params row",
        )
        candidate = _candidate_parameters()

        def fake_evaluate(
            reviews: tuple[optimize.Review, ...],
            train_count: int,
            parameters: tuple[float, ...],
            desired_retention: float,
        ) -> optimize.Evaluation:
            del reviews, train_count, desired_retention
            return _evaluation(0.40 if tuple(parameters) == candidate else 0.20)

        analysis = optimize.analyze(
            _reviews(1000),
            cards_read=40,
            current_config=current,
            fit_function=lambda _: candidate,
            evaluate_function=fake_evaluate,
        )
        self.assertFalse(analysis.recommended)
        self.assertIn("did not beat current", analysis.refusal_reason or "")


class SyntheticGenerationTests(unittest.TestCase):
    def _known_generation(self) -> tuple[optimize.Review, ...]:
        from fsrs import Card, Rating

        known = optimize.DART_DEFAULT_PARAMETERS
        scheduler = optimize._make_scheduler(known, 0.9)
        start = datetime(2020, 1, 1, tzinfo=timezone.utc)
        rng = random.Random(42)
        generated: list[optimize.Review] = []
        for card_id in range(128):
            card = Card(card_id=card_id, due=start)
            for review_index in range(8):
                reviewed_at = start + timedelta(
                    days=review_index * 28 + card_id % 7
                )
                probability = scheduler.get_card_retrievability(
                    card=card,
                    current_datetime=reviewed_at,
                )
                if review_index == 0:
                    rating = Rating.Good
                elif rng.random() > probability:
                    rating = Rating.Again
                else:
                    bucket = rng.random()
                    rating = (
                        Rating.Hard
                        if bucket < 0.18
                        else Rating.Good
                        if bucket < 0.90
                        else Rating.Easy
                    )
                generated.append(
                    optimize.Review(
                        card_id=card_id,
                        rating=int(rating),
                        rating_at=reviewed_at,
                        row_id=len(generated),
                    )
                )
                card, _ = scheduler.review_card(
                    card=card,
                    rating=rating,
                    review_datetime=reviewed_at,
                    review_duration=None,
                )
        return tuple(sorted(generated, key=lambda item: (item.rating_at, item.row_id)))

    def test_fit_recovers_known_generation_within_normalized_tolerance(self) -> None:
        generated = self._known_generation()
        train, _ = optimize.chronological_split(generated)
        fitted = optimize.fit_parameters(train)
        normalized_rms = math.sqrt(
            sum(
                (
                    (actual - expected)
                    / (upper - lower)
                )
                ** 2
                for actual, expected, lower, upper in zip(
                    fitted,
                    optimize.DART_DEFAULT_PARAMETERS,
                    optimize.DART_LOWER_BOUNDS,
                    optimize.DART_UPPER_BOUNDS,
                )
            )
            / len(fitted)
        )
        self.assertLess(
            normalized_rms,
            0.20,
            msg=f"fitted parameters drifted too far: {fitted}",
        )


class FixtureAndReadOnlyTests(unittest.TestCase):
    def test_fixture_produces_report_and_exact_machine_shape(self) -> None:
        reviews, cards, raw_fsrs = optimize._fixture_payload(FIXTURE)
        current = optimize.parse_fsrs_config(raw_fsrs, "fixture fsrs_params")
        candidate = _candidate_parameters()

        def fake_evaluate(
            reviews: tuple[optimize.Review, ...],
            train_count: int,
            parameters: tuple[float, ...],
            desired_retention: float,
        ) -> optimize.Evaluation:
            del reviews, train_count, desired_retention
            return _evaluation(0.10 if tuple(parameters) == candidate else 0.20)

        analysis = optimize.analyze(
            reviews,
            cards_read=len(cards),
            current_config=current,
            effective_retention=0.9,
            fit_function=lambda _: candidate,
            evaluate_function=fake_evaluate,
        )
        self.assertTrue(analysis.recommended)
        report = optimize.render_report(analysis)
        self.assertIn("RECOMMENDED", report)
        self.assertIn("Holdout evaluation", report)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "params.json"
            optimize._write_text(
                output,
                json.dumps(analysis.fitted.machine_json(), indent=2) + "\n",
            )
            payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(set(payload), {"parameters", "desired_retention"})
        self.assertEqual(len(payload["parameters"]), 21)
        self.assertEqual(payload["desired_retention"], 0.9)

    def test_supabase_reader_uses_get_only_and_scopes_user(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps(
            [{"settings_value": {"parameters": list(optimize.DART_DEFAULT_PARAMETERS)}}]
        ).encode("utf-8")
        client = optimize.SupabaseReadClient(
            "https://example.invalid",
            "service-key-not-printed",
            "user-123",
        )
        with mock.patch.object(
            optimize.urllib.request,
            "urlopen",
            return_value=response,
        ) as urlopen:
            value = client.fetch_setting("fsrs_params")
        request = urlopen.call_args.args[0]
        self.assertEqual(request.method, "GET")
        self.assertIn("user_id=eq.user-123", request.full_url)
        self.assertEqual(value["parameters"][0], optimize.DART_DEFAULT_PARAMETERS[0])


if __name__ == "__main__":
    unittest.main()

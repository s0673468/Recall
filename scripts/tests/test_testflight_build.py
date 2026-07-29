from __future__ import annotations

import base64
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import testflight_build as delivery


def decode_segment(segment: str) -> dict[str, object]:
    padding = "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(segment + padding))


class FakeClient:
    def __init__(self, responses: dict[tuple[str, str], list[dict]]) -> None:
        self.responses = {key: list(value) for key, value in responses.items()}
        self.calls: list[tuple[str, str, object]] = []

    def request(self, method: str, path: str, body=None):
        self.calls.append((method, path, body))
        key = (method, path)
        if key not in self.responses or not self.responses[key]:
            raise AssertionError(f"unexpected HTTP request: {method} {path}")
        return self.responses[key].pop(0)


def product_response() -> dict:
    return {
        "data": [
            {
                "type": "ciProducts",
                "id": "product-track",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": "app-track"}}
                },
            },
            {
                "type": "ciProducts",
                "id": "product-recall",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": "app-recall"}}
                },
            },
        ],
        "included": [
            {
                "type": "apps",
                "id": "app-track",
                "attributes": {"bundleId": "com.health.track"},
            },
            {
                "type": "apps",
                "id": "app-recall",
                "attributes": {"bundleId": delivery.BUNDLE_ID},
            },
        ],
    }


def workflow_response(name: str = delivery.DEFAULT_WORKFLOW) -> dict:
    return {
        "data": [
            {
                "type": "ciWorkflows",
                "id": "workflow-recall",
                "attributes": {"name": name, "isEnabled": True},
            }
        ]
    }


def repository_response() -> dict:
    return {
        "data": [
            {"type": "scmRepositories", "id": "repository-recall"}
        ]
    }


def reference_response(branch: str = "main") -> dict:
    return {
        "data": [
            {
                "type": "scmGitReferences",
                "id": "tag-main",
                "attributes": {
                    "kind": "TAG",
                    "name": branch,
                    "isDeleted": False,
                },
            },
            {
                "type": "scmGitReferences",
                "id": "reference-main",
                "attributes": {
                    "kind": "BRANCH",
                    "name": branch,
                    "isDeleted": False,
                },
            },
        ]
    }


def resolution_responses() -> dict[tuple[str, str], list[dict]]:
    return {
        ("GET", "/ciProducts?include=app&limit=200"): [product_response()],
        (
            "GET",
            "/ciProducts/product-recall/workflows?limit=200",
        ): [workflow_response()],
        (
            "GET",
            "/ciProducts/product-recall/primaryRepositories?limit=200",
        ): [repository_response()],
        (
            "GET",
            "/scmRepositories/repository-recall/gitReferences?limit=200",
        ): [reference_response()],
    }


class JwtTests(unittest.TestCase):
    def test_jwt_header_claims_and_signature_shape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory) / "AuthKey_TESTKEY.p8"
            subprocess.run(
                [
                    "openssl",
                    "ecparam",
                    "-name",
                    "prime256v1",
                    "-genkey",
                    "-noout",
                    "-out",
                    str(key_path),
                ],
                check=True,
                capture_output=True,
            )
            credentials = delivery.Credentials(
                key_id="TESTKEY",
                issuer_id="issuer-test",
                key_path=key_path,
            )
            token = delivery.mint_jwt(credentials, issued_at=1_700_000_000)

            header_segment, claims_segment, signature_segment = token.split(".")
            self.assertEqual(
                decode_segment(header_segment),
                {"alg": "ES256", "kid": "TESTKEY", "typ": "JWT"},
            )
            claims = decode_segment(claims_segment)
            self.assertEqual(claims["iss"], "issuer-test")
            self.assertEqual(claims["iat"], 1_700_000_000)
            self.assertEqual(claims["exp"], 1_700_001_199)
            self.assertLessEqual(
                int(claims["exp"]) - int(claims["iat"]), 20 * 60
            )
            self.assertEqual(claims["aud"], "appstoreconnect-v1")

            padding = "=" * (-len(signature_segment) % 4)
            raw_signature = base64.urlsafe_b64decode(
                signature_segment + padding
            )
            self.assertEqual(len(raw_signature), 64)


class ResolutionTests(unittest.TestCase):
    def test_resolves_product_workflow_and_branch_reference(self) -> None:
        client = FakeClient(resolution_responses())
        target = delivery.resolve_target(
            client,
            workflow_name=delivery.DEFAULT_WORKFLOW,
            branch="main",
        )
        self.assertEqual(target.product_id, "product-recall")
        self.assertEqual(target.workflow_id, "workflow-recall")
        self.assertEqual(target.repository_id, "repository-recall")
        self.assertEqual(target.reference_id, "reference-main")

    def test_build_run_request_body(self) -> None:
        target = delivery.BuildTarget(
            product_id="product",
            workflow_id="workflow",
            workflow_name="Recall workflow",
            repository_id="repository",
            reference_id="reference",
            branch="release",
        )
        self.assertEqual(
            delivery.build_run_body(target),
            {
                "data": {
                    "type": "ciBuildRuns",
                    "attributes": {"clean": False},
                    "relationships": {
                        "workflow": {
                            "data": {
                                "type": "ciWorkflows",
                                "id": "workflow",
                            }
                        },
                        "sourceBranchOrTag": {
                            "data": {
                                "type": "scmGitReferences",
                                "id": "reference",
                            }
                        },
                    },
                }
            },
        )


class PollingTests(unittest.TestCase):
    def test_success_polling_path(self) -> None:
        client = FakeClient(
            {
                ("GET", "/ciBuildRuns/run-1"): [
                    {
                        "data": {
                            "id": "run-1",
                            "attributes": {
                                "number": 42,
                                "executionProgress": "RUNNING",
                                "completionStatus": None,
                            },
                        }
                    },
                    {
                        "data": {
                            "id": "run-1",
                            "attributes": {
                                "number": 42,
                                "executionProgress": "COMPLETE",
                                "completionStatus": "SUCCEEDED",
                            },
                        }
                    },
                ]
            }
        )
        initial = {
            "data": {
                "id": "run-1",
                "attributes": {
                    "number": 42,
                    "executionProgress": "PENDING",
                    "completionStatus": None,
                },
            }
        }
        output = io.StringIO()
        sleeps: list[float] = []
        status = delivery.poll_build(
            client,
            initial,
            output=output,
            sleep=sleeps.append,
            poll_interval=0.25,
        )
        self.assertEqual(status, "SUCCEEDED")
        self.assertEqual(sleeps, [0.25, 0.25])
        self.assertIn("Build 42: execution PENDING", output.getvalue())
        self.assertIn(
            "Build 42: execution COMPLETE, completion SUCCEEDED",
            output.getvalue(),
        )

    def test_failed_build_returns_nonzero(self) -> None:
        responses = resolution_responses()
        responses[("POST", "/ciBuildRuns")] = [
            {
                "data": {
                    "id": "run-2",
                    "attributes": {
                        "number": 43,
                        "executionProgress": "COMPLETE",
                        "completionStatus": "FAILED",
                    },
                }
            }
        ]
        client = FakeClient(responses)
        output = io.StringIO()
        error = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            key_path = (
                home
                / ".appstoreconnect"
                / "private_keys"
                / "AuthKey_TESTKEY.p8"
            )
            key_path.parent.mkdir(parents=True)
            subprocess.run(
                [
                    "openssl",
                    "ecparam",
                    "-name",
                    "prime256v1",
                    "-genkey",
                    "-noout",
                    "-out",
                    str(key_path),
                ],
                check=True,
                capture_output=True,
            )
            exit_code = delivery.run(
                [],
                environ={
                    "ASC_KEY_ID": "TESTKEY",
                    "ASC_ISSUER_ID": "issuer-test",
                },
                home=home,
                client_factory=lambda _token_provider: client,
                sleep=lambda _seconds: None,
                issued_at=1_700_000_000,
                output=output,
                error_output=error,
            )
        self.assertEqual(exit_code, 1)
        self.assertEqual(error.getvalue(), "")
        self.assertIn("completion FAILED", output.getvalue())


class MissingPrerequisiteTests(unittest.TestCase):
    def assert_single_error(
        self,
        *,
        environ: dict[str, str],
        expected: str,
        home: Path,
    ) -> None:
        output = io.StringIO()
        error = io.StringIO()
        exit_code = delivery.run(
            ["--dry-run"],
            environ=environ,
            home=home,
            client_factory=lambda _token_provider: self.fail(
                "network client created"
            ),
            output=output,
            error_output=error,
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(len(error.getvalue().splitlines()), 1)
        self.assertIn(expected, error.getvalue())
        self.assertNotIn("Traceback", error.getvalue())

    def test_missing_api_key_setup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assert_single_error(
                environ={},
                expected="App Store Connect API key is missing",
                home=Path(directory),
            )

    def test_missing_key_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assert_single_error(
                environ={"ASC_ISSUER_ID": "issuer"},
                expected="ASC_KEY_ID is missing",
                home=Path(directory),
            )

    def test_missing_issuer_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assert_single_error(
                environ={"ASC_KEY_ID": "KEY"},
                expected="ASC_ISSUER_ID is missing",
                home=Path(directory),
            )

    def test_missing_private_key_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assert_single_error(
                environ={
                    "ASC_KEY_ID": "KEY",
                    "ASC_ISSUER_ID": "issuer",
                },
                expected="App Store Connect API private key is missing",
                home=Path(directory),
            )

    def test_missing_product(self) -> None:
        client = FakeClient(
            {
                ("GET", "/ciProducts?include=app&limit=200"): [
                    {"data": [], "included": []}
                ]
            }
        )
        with self.assertRaisesRegex(
            delivery.DeliveryError, "create the standalone Recall product"
        ):
            delivery.resolve_product(client)

    def test_missing_workflow(self) -> None:
        client = FakeClient(
            {
                (
                    "GET",
                    "/ciProducts/product/workflows?limit=200",
                ): [{"data": []}]
            }
        )
        with self.assertRaisesRegex(
            delivery.DeliveryError,
            "create an enabled manual workflow named",
        ):
            delivery.resolve_workflow(
                client,
                product_id="product",
                workflow_name=delivery.DEFAULT_WORKFLOW,
            )

    def test_missing_reference(self) -> None:
        client = FakeClient(
            {
                (
                    "GET",
                    "/ciProducts/product/primaryRepositories?limit=200",
                ): [repository_response()],
                (
                    "GET",
                    "/scmRepositories/repository-recall/gitReferences?limit=200",
                ): [{"data": []}],
            }
        )
        with self.assertRaisesRegex(
            delivery.DeliveryError, "push branch 'main'"
        ):
            delivery.resolve_reference(
                client, product_id="product", branch="main"
            )


class NoNetworkTests(unittest.TestCase):
    def test_suite_replaces_urlopen(self) -> None:
        with mock.patch(
            "urllib.request.urlopen",
            side_effect=AssertionError("live network call"),
        ):
            client = FakeClient(resolution_responses())
            delivery.resolve_target(
                client,
                workflow_name=delivery.DEFAULT_WORKFLOW,
                branch="main",
            )


if __name__ == "__main__":
    unittest.main()

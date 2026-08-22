from __future__ import annotations

import base64
import http.client
import io
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import testflight_build as delivery


def decode_segment(segment: str) -> dict[str, object]:
    padding = "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(segment + padding))


class FakeClient:
    def __init__(
        self, responses: dict[tuple[str, str], list[object]]
    ) -> None:
        self.responses = {key: list(value) for key, value in responses.items()}
        self.calls: list[tuple[str, str, object]] = []

    def request(self, method: str, path: str, body=None):
        self.calls.append((method, path, body))
        key = (method, path)
        if key not in self.responses or not self.responses[key]:
            raise AssertionError(f"unexpected HTTP request: {method} {path}")
        response = self.responses[key].pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


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
            {
                "type": "scmRepositories",
                "id": "repository-recall",
                "attributes": {
                    "ownerName": "s0673468",
                    "repositoryName": "Recall",
                },
            }
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
            app_id="app-recall",
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
                (
                    "GET",
                    "/ciBuildRuns/run-1?fields[ciBuildRuns]="
                    "number,executionProgress,completionStatus,sourceCommit,"
                    "finishedDate",
                ): [
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
                release_gate=lambda _branch: "a" * 40,
                sleep=lambda _seconds: None,
                issued_at=1_700_000_000,
                output=output,
                error_output=error,
            )
        self.assertEqual(exit_code, 1)
        self.assertEqual(error.getvalue(), "")
        self.assertIn("completion FAILED", output.getvalue())

    def test_transient_build_poll_is_retried_without_new_post(self) -> None:
        path = (
            "/ciBuildRuns/run-42?fields[ciBuildRuns]="
            "number,executionProgress,completionStatus,sourceCommit,finishedDate"
        )
        client = FakeClient(
            {
                ("GET", path): [
                    delivery.TransientReadError(
                        "temporary throttling", retry_after=2.0
                    ),
                    {
                        "data": {
                            "id": "run-42",
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
        sleeps: list[float] = []

        self.assertEqual(
            delivery.poll_build(
                client,
                {
                    "data": {
                        "id": "run-42",
                        "attributes": {
                            "number": 42,
                            "executionProgress": "PENDING",
                        },
                    }
                },
                output=io.StringIO(),
                sleep=sleeps.append,
                poll_interval=0.25,
            ),
            "SUCCEEDED",
        )
        self.assertEqual(sleeps, [0.25, 2.0])
        self.assertEqual(
            [call[0] for call in client.calls],
            ["GET", "GET"],
        )


class AppStoreConnectClientTests(unittest.TestCase):
    def test_get_429_exposes_retry_after_without_credentials(self) -> None:
        key_id = "NEVER-LOG-THIS"
        http_error = urllib.error.HTTPError(
            f"{delivery.API_BASE}/ciBuildRuns/run-1",
            429,
            "Too Many Requests",
            {"Retry-After": "3"},
            None,
        )
        client = delivery.AppStoreConnectClient(
            lambda: f"token-for-{key_id}",
            opener=mock.Mock(side_effect=http_error),
        )

        with self.assertRaises(delivery.TransientReadError) as raised:
            client.request("GET", "/ciBuildRuns/run-1")

        self.assertEqual(raised.exception.retry_after, 3.0)
        self.assertNotIn(key_id, str(raised.exception))

    def test_post_429_is_not_retryable(self) -> None:
        http_error = urllib.error.HTTPError(
            f"{delivery.API_BASE}/ciBuildRuns",
            429,
            "Too Many Requests",
            {"Retry-After": "3"},
            None,
        )
        client = delivery.AppStoreConnectClient(
            lambda: "token",
            opener=mock.Mock(side_effect=http_error),
        )

        with self.assertRaises(delivery.DeliveryError) as raised:
            client.request("POST", "/ciBuildRuns", {"data": {}})

        self.assertNotIsInstance(
            raised.exception, delivery.TransientReadError
        )

    def test_get_response_read_timeout_is_retryable(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.side_effect = TimeoutError(
            "read timed out"
        )
        client = delivery.AppStoreConnectClient(
            lambda: "token",
            opener=mock.Mock(return_value=response),
        )

        with self.assertRaises(delivery.TransientReadError):
            client.request("GET", "/ciBuildRuns/run-1")

    def test_post_response_read_timeout_is_not_retryable(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.side_effect = TimeoutError(
            "read timed out"
        )
        client = delivery.AppStoreConnectClient(
            lambda: "token",
            opener=mock.Mock(return_value=response),
        )

        with self.assertRaises(delivery.DeliveryError) as raised:
            client.request("POST", "/ciBuildRuns", {"data": {}})

        self.assertNotIsInstance(
            raised.exception, delivery.TransientReadError
        )

    def test_get_incomplete_or_reset_body_is_retryable(self) -> None:
        for read_error in (
            http.client.IncompleteRead(b"partial"),
            ConnectionResetError("peer reset"),
        ):
            with self.subTest(error=type(read_error).__name__):
                response = mock.MagicMock()
                response.__enter__.return_value.read.side_effect = read_error
                client = delivery.AppStoreConnectClient(
                    lambda: "token",
                    opener=mock.Mock(return_value=response),
                )

                with self.assertRaises(delivery.TransientReadError):
                    client.request("GET", "/ciBuildRuns/run-1")

    def test_post_incomplete_body_requires_inspection_before_retry(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.side_effect = (
            http.client.IncompleteRead(b"partial")
        )
        client = delivery.AppStoreConnectClient(
            lambda: "token",
            opener=mock.Mock(return_value=response),
        )

        with self.assertRaises(delivery.DeliveryError) as raised:
            client.request("POST", "/ciBuildRuns", {"data": {}})

        self.assertNotIsInstance(
            raised.exception, delivery.TransientReadError
        )
        self.assertIn("inspect Xcode Cloud", str(raised.exception))

    def test_post_url_error_requires_inspection_before_retry(self) -> None:
        client = delivery.AppStoreConnectClient(
            lambda: "token",
            opener=mock.Mock(
                side_effect=urllib.error.URLError("connection lost")
            ),
        )

        with self.assertRaises(delivery.DeliveryError) as raised:
            client.request("POST", "/ciBuildRuns", {"data": {}})

        self.assertNotIsInstance(
            raised.exception, delivery.TransientReadError
        )
        self.assertIn("inspect Xcode Cloud", str(raised.exception))

    def test_get_truncated_json_is_retryable(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'{"data":'
        client = delivery.AppStoreConnectClient(
            lambda: "token",
            opener=mock.Mock(return_value=response),
        )

        with self.assertRaises(delivery.TransientReadError):
            client.request("GET", "/ciBuildRuns/run-1")

    def test_post_truncated_or_empty_json_requires_inspection(self) -> None:
        for body in (b'{"data":', b""):
            with self.subTest(body=body):
                response = mock.MagicMock()
                response.__enter__.return_value.read.return_value = body
                client = delivery.AppStoreConnectClient(
                    lambda: "token",
                    opener=mock.Mock(return_value=response),
                )

                with self.assertRaises(delivery.DeliveryError) as raised:
                    client.request("POST", "/ciBuildRuns", {"data": {}})

                self.assertNotIsInstance(
                    raised.exception, delivery.TransientReadError
                )
                self.assertIn("inspect Xcode Cloud", str(raised.exception))


class GitHubReleaseGateTests(unittest.TestCase):
    def test_requires_strict_green_required_check_on_exact_tip(self) -> None:
        sha = "a" * 40
        responses = {
            "repos/s0673468/Recall/branches/main": {
                "commit": {"sha": sha}
            },
            "repos/s0673468/Recall/branches/main/protection": {
                "required_status_checks": {
                    "strict": True,
                    "contexts": ["flutter"],
                    "checks": [{"context": "flutter"}],
                }
            },
            f"repos/s0673468/Recall/commits/{sha}/check-runs?per_page=100": {
                "check_runs": [
                    {
                        "id": 1,
                        "name": "flutter",
                        "status": "completed",
                        "conclusion": "failure",
                    },
                    {
                        "id": 2,
                        "name": "flutter",
                        "status": "completed",
                        "conclusion": "success",
                    },
                ]
            },
        }

        self.assertEqual(
            delivery.verify_github_release(
                "main", api_get=lambda path: responses[path]
            ),
            sha,
        )

    def test_rejects_missing_required_check(self) -> None:
        sha = "b" * 40
        responses = {
            "repos/s0673468/Recall/branches/main": {
                "commit": {"sha": sha}
            },
            "repos/s0673468/Recall/branches/main/protection": {
                "required_status_checks": {
                    "strict": True,
                    "contexts": ["flutter"],
                }
            },
            f"repos/s0673468/Recall/commits/{sha}/check-runs?per_page=100": {
                "check_runs": []
            },
        }

        with self.assertRaisesRegex(
            delivery.DeliveryError, "required GitHub check 'flutter' is missing"
        ):
            delivery.verify_github_release(
                "main", api_get=lambda path: responses[path]
            )


class TestFlightReadbackTests(unittest.TestCase):
    def target(self) -> delivery.BuildTarget:
        return delivery.BuildTarget(
            app_id="app-recall",
            product_id="product-recall",
            workflow_id="workflow-recall",
            workflow_name=delivery.DEFAULT_WORKFLOW,
            repository_id="repository-recall",
            reference_id="reference-main",
            branch="main",
        )

    def test_requires_valid_build_attached_to_internal_german_group(self) -> None:
        group_query = urllib.parse.urlencode(
            {
                "filter[app]": "app-recall",
                "filter[name]": "German",
                "filter[isInternalGroup]": "true",
                "limit": 200,
            }
        )
        client = FakeClient(
            {
                (
                    "GET",
                    "/ciBuildRuns/run-52/builds?"
                    "fields[builds]=version,processingState,"
                    "usesNonExemptEncryption",
                ): [
                    {
                        "data": [
                            {
                                "type": "builds",
                                "id": "build-52",
                                "attributes": {
                                    "version": "52",
                                    "processingState": "VALID",
                                    "usesNonExemptEncryption": False,
                                },
                            }
                        ]
                    }
                ],
                ("GET", f"/betaGroups?{group_query}"): [
                    {
                        "data": [
                            {
                                "type": "betaGroups",
                                "id": "group-german",
                                "attributes": {
                                    "name": "German",
                                    "isInternalGroup": True,
                                },
                            }
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/betaTesters?"
                    "limit=200",
                ): [
                    {
                        "data": [
                            {"type": "betaTesters", "id": "tester-german"}
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/builds?limit=200",
                ): [
                    {"data": [{"type": "builds", "id": "build-52"}]}
                ],
            }
        )
        output = io.StringIO()

        self.assertEqual(
            delivery.poll_testflight(
                client,
                run_id="run-52",
                target=self.target(),
                output=output,
                sleep=lambda _seconds: None,
            ),
            "build-52",
        )
        self.assertIn(
            "VALID, attached to internal group German, and available to 1 "
            "eligible tester",
            output.getvalue(),
        )
        self.assertFalse(
            any("filter%5Bbuilds%5D" in path for _, path, _ in client.calls)
        )

    def test_times_out_when_german_group_is_not_attached(self) -> None:
        group_query = urllib.parse.urlencode(
            {
                "filter[app]": "app-recall",
                "filter[name]": "German",
                "filter[isInternalGroup]": "true",
                "limit": 200,
            }
        )
        client = FakeClient(
            {
                (
                    "GET",
                    "/ciBuildRuns/run-53/builds?"
                    "fields[builds]=version,processingState,"
                    "usesNonExemptEncryption",
                ): [
                    {
                        "data": [
                            {
                                "type": "builds",
                                "id": "build-53",
                                "attributes": {
                                    "version": "53",
                                    "processingState": "VALID",
                                    "usesNonExemptEncryption": False,
                                },
                            }
                        ]
                    }
                ],
                ("GET", f"/betaGroups?{group_query}"): [
                    {
                        "data": [
                            {
                                "type": "betaGroups",
                                "id": "group-german",
                                "attributes": {
                                    "name": "German",
                                    "isInternalGroup": True,
                                },
                            }
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/betaTesters?"
                    "limit=200",
                ): [
                    {
                        "data": [
                            {"type": "betaTesters", "id": "tester-german"}
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/builds?limit=200",
                ): [{"data": []}],
            }
        )
        clock = iter([0.0, 2.0])

        with self.assertRaisesRegex(
            delivery.DeliveryError,
            "timed out waiting for a VALID TestFlight build",
        ):
            delivery.poll_testflight(
                client,
                run_id="run-53",
                target=self.target(),
                output=io.StringIO(),
                sleep=lambda _seconds: None,
                timeout=1,
                monotonic=lambda: next(clock),
            )

    def test_rejects_an_internal_group_without_an_eligible_tester(self) -> None:
        group_query = urllib.parse.urlencode(
            {
                "filter[app]": "app-recall",
                "filter[name]": "German",
                "filter[isInternalGroup]": "true",
                "limit": 200,
            }
        )
        client = FakeClient(
            {
                (
                    "GET",
                    "/ciBuildRuns/run-54/builds?"
                    "fields[builds]=version,processingState,"
                    "usesNonExemptEncryption",
                ): [
                    {
                        "data": [
                            {
                                "type": "builds",
                                "id": "build-54",
                                "attributes": {
                                    "version": "54",
                                    "processingState": "VALID",
                                    "usesNonExemptEncryption": False,
                                },
                            }
                        ]
                    }
                ],
                ("GET", f"/betaGroups?{group_query}"): [
                    {
                        "data": [
                            {
                                "type": "betaGroups",
                                "id": "group-german",
                                "attributes": {
                                    "name": "German",
                                    "isInternalGroup": True,
                                },
                            }
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/betaTesters?"
                    "limit=200",
                ): [{"data": []}],
            }
        )

        with self.assertRaisesRegex(
            delivery.DeliveryError,
            "has no eligible testers",
        ):
            delivery.poll_testflight(
                client,
                run_id="run-54",
                target=self.target(),
                output=io.StringIO(),
                sleep=lambda _seconds: None,
            )

    def test_follows_group_build_pagination_to_find_the_current_build(self) -> None:
        group_query = urllib.parse.urlencode(
            {
                "filter[app]": "app-recall",
                "filter[name]": "German",
                "filter[isInternalGroup]": "true",
                "limit": 200,
            }
        )
        next_page = (
            "https://api.appstoreconnect.apple.com/v1/betaGroups/"
            "group-german/relationships/builds?cursor=next-page"
        )
        builds_path = (
            "/ciBuildRuns/run-55/builds?"
            "fields[builds]=version,processingState,"
            "usesNonExemptEncryption"
        )
        client = FakeClient(
            {
                ("GET", builds_path): [
                    {
                        "data": [
                            {
                                "type": "builds",
                                "id": "build-55",
                                "attributes": {
                                    "version": "55",
                                    "processingState": "VALID",
                                    "usesNonExemptEncryption": False,
                                },
                            }
                        ]
                    }
                ],
                ("GET", f"/betaGroups?{group_query}"): [
                    {
                        "data": [
                            {
                                "type": "betaGroups",
                                "id": "group-german",
                                "attributes": {
                                    "name": "German",
                                    "isInternalGroup": True,
                                },
                            }
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/betaTesters?"
                    "limit=200",
                ): [
                    {
                        "data": [
                            {"type": "betaTesters", "id": "tester-german"}
                        ]
                    }
                ],
                (
                    "GET",
                    "/betaGroups/group-german/relationships/builds?limit=200",
                ): [
                    {
                        "data": [
                            {
                                "type": "builds",
                                "id": f"historical-{number}",
                            }
                            for number in range(200)
                        ],
                        "links": {"next": next_page},
                    }
                ],
                ("GET", next_page): [
                    {"data": [{"type": "builds", "id": "build-55"}]}
                ],
            }
        )

        self.assertEqual(
            delivery.poll_testflight(
                client,
                run_id="run-55",
                target=self.target(),
                output=io.StringIO(),
                sleep=lambda _seconds: None,
            ),
            "build-55",
        )


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
            release_gate=lambda _branch: "a" * 40,
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
            key_id = "NEVER-LOG-THIS"
            output = io.StringIO()
            error = io.StringIO()
            exit_code = delivery.run(
                ["--dry-run"],
                environ={
                    "ASC_KEY_ID": key_id,
                    "ASC_ISSUER_ID": "issuer",
                },
                home=Path(directory),
                release_gate=lambda _branch: "a" * 40,
                output=output,
                error_output=error,
            )
            self.assertEqual(exit_code, 1)
            self.assertIn(
                "App Store Connect API private key is missing",
                error.getvalue(),
            )
            self.assertIn("AuthKey_<KEY_ID>.p8", error.getvalue())
            self.assertNotIn(key_id, error.getvalue())

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

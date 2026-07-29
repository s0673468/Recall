#!/usr/bin/env python3
"""Start and monitor Recall's manual Xcode Cloud TestFlight workflow."""

from __future__ import annotations

import argparse
import base64
import json
import os
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, TextIO

API_BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.german.ankiReview"
DEFAULT_WORKFLOW = "Recall Internal TestFlight"
DEFAULT_BRANCH = "main"
TOKEN_LIFETIME_SECONDS = 1_199
REQUEST_TIMEOUT_SECONDS = 30
DEFAULT_POLL_INTERVAL_SECONDS = 15.0
DEFAULT_TIMEOUT_SECONDS = 2 * 60 * 60
SUCCESS_STATUS = "SUCCEEDED"
TERMINAL_PROGRESS = "COMPLETE"
GITHUB_REPOSITORY = "s0673468/Recall"
TESTFLIGHT_GROUP = "German"


class DeliveryError(RuntimeError):
    """A configuration or App Store Connect error safe to show to the user."""


@dataclass(frozen=True)
class Credentials:
    key_id: str
    issuer_id: str
    key_path: Path


@dataclass(frozen=True)
class BuildTarget:
    app_id: str
    product_id: str
    workflow_id: str
    workflow_name: str
    repository_id: str
    reference_id: str
    branch: str


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _read_der_length(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise DeliveryError("openssl returned an invalid ES256 signature")
    first = data[offset]
    if first < 0x80:
        return first, offset + 1
    count = first & 0x7F
    if count == 0 or count > 2 or offset + 1 + count > len(data):
        raise DeliveryError("openssl returned an invalid ES256 signature")
    start = offset + 1
    return int.from_bytes(data[start : start + count], "big"), start + count


def _der_signature_to_jose(signature: bytes) -> bytes:
    """Convert OpenSSL's DER ECDSA signature to JWT's fixed-width R || S."""
    if not signature or signature[0] != 0x30:
        raise DeliveryError("openssl returned an invalid ES256 signature")
    sequence_length, offset = _read_der_length(signature, 1)
    if offset + sequence_length != len(signature):
        raise DeliveryError("openssl returned an invalid ES256 signature")

    integers: list[bytes] = []
    for _ in range(2):
        if offset >= len(signature) or signature[offset] != 0x02:
            raise DeliveryError("openssl returned an invalid ES256 signature")
        length, value_offset = _read_der_length(signature, offset + 1)
        value = signature[value_offset : value_offset + length]
        if len(value) != length:
            raise DeliveryError("openssl returned an invalid ES256 signature")
        value = value.lstrip(b"\x00")
        if len(value) > 32:
            raise DeliveryError("openssl returned an invalid ES256 signature")
        integers.append(value.rjust(32, b"\x00"))
        offset = value_offset + length

    if offset != len(signature):
        raise DeliveryError("openssl returned an invalid ES256 signature")
    return b"".join(integers)


def jwt_parts(
    *, key_id: str, issuer_id: str, issued_at: int
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return the documented App Store Connect JWT header and claims."""
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {
        "iss": issuer_id,
        "iat": issued_at,
        "exp": issued_at + TOKEN_LIFETIME_SECONDS,
        "aud": "appstoreconnect-v1",
    }
    return header, claims


def mint_jwt(credentials: Credentials, *, issued_at: int | None = None) -> str:
    """Mint an ES256 JWT without printing the private key or resulting token."""
    header, claims = jwt_parts(
        key_id=credentials.key_id,
        issuer_id=credentials.issuer_id,
        issued_at=int(time.time()) if issued_at is None else issued_at,
    )
    signing_input = (
        f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{_b64url(json.dumps(claims, separators=(',', ':')).encode())}"
    )
    try:
        result = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-sign",
                str(credentials.key_path),
            ],
            input=signing_input.encode("ascii"),
            capture_output=True,
            check=False,
        )
    except FileNotFoundError as error:
        raise DeliveryError(
            "openssl is missing; install the macOS command-line tools before "
            "running this script"
        ) from error
    if result.returncode != 0:
        raise DeliveryError(
            "the App Store Connect private key could not sign an ES256 token; "
            "confirm that the AuthKey file is a valid .p8 key"
        )
    signature = _der_signature_to_jose(result.stdout)
    return f"{signing_input}.{_b64url(signature)}"


def credentials_from_environment(
    environ: Mapping[str, str], *, home: Path
) -> Credentials:
    """Resolve the two documented environment variables and fixed key path."""
    key_id = environ.get("ASC_KEY_ID", "").strip()
    issuer_id = environ.get("ASC_ISSUER_ID", "").strip()
    if not key_id and not issuer_id:
        raise DeliveryError(
            "App Store Connect API key is missing: create a Team API key in "
            "App Store Connect > Users and Access > Integrations, set "
            "ASC_KEY_ID and ASC_ISSUER_ID, and save its private key as "
            "~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"
        )
    if not key_id:
        raise DeliveryError(
            "ASC_KEY_ID is missing: set it to the Key ID of the App Store "
            "Connect Team API key"
        )
    if not issuer_id:
        raise DeliveryError(
            "ASC_ISSUER_ID is missing: set it to the Issuer ID shown in App "
            "Store Connect > Users and Access > Integrations"
        )

    key_path = (
        home
        / ".appstoreconnect"
        / "private_keys"
        / f"AuthKey_{key_id}.p8"
    )
    if not key_path.is_file():
        raise DeliveryError(
            "App Store Connect API private key is missing: download the Team "
            f"API key and save it as {key_path}"
        )
    key_stat = key_path.stat()
    if (
        key_path.is_symlink()
        or not stat.S_ISREG(key_stat.st_mode)
        or key_stat.st_uid != os.getuid()
    ):
        raise DeliveryError(
            "App Store Connect API private key must be a regular, non-symlink, "
            "owner-owned file"
        )
    if stat.S_IMODE(key_stat.st_mode) & 0o077:
        raise DeliveryError(
            f"App Store Connect API private key is too permissive; run "
            f"chmod 600 {key_path}"
        )
    return Credentials(key_id=key_id, issuer_id=issuer_id, key_path=key_path)


def _gh_api(path: str) -> Mapping[str, Any]:
    try:
        result = subprocess.run(
            ["gh", "api", path],
            capture_output=True,
            check=False,
            text=True,
        )
    except FileNotFoundError as error:
        raise DeliveryError(
            "GitHub CLI is missing; install and authenticate gh before shipping"
        ) from error
    if result.returncode != 0:
        raise DeliveryError(
            "GitHub release-gate readback failed; run gh auth status and retry"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise DeliveryError("GitHub returned an unreadable release-gate response")
    if not isinstance(payload, Mapping):
        raise DeliveryError("GitHub returned an invalid release-gate response")
    return payload


def verify_github_release(
    branch: str,
    *,
    api_get: Callable[[str], Mapping[str, Any]] = _gh_api,
) -> str:
    """Return the exact protected, green GitHub branch tip."""
    encoded_branch = urllib.parse.quote(branch, safe="")
    branch_path = f"repos/{GITHUB_REPOSITORY}/branches/{encoded_branch}"
    branch_payload = api_get(branch_path)
    commit = branch_payload.get("commit")
    sha = commit.get("sha") if isinstance(commit, Mapping) else None
    if not isinstance(sha, str) or not sha:
        raise DeliveryError(f"GitHub branch {branch!r} has no readable tip")

    protection = api_get(f"{branch_path}/protection")
    required = protection.get("required_status_checks")
    if not isinstance(required, Mapping) or required.get("strict") is not True:
        raise DeliveryError(
            f"GitHub branch {branch!r} is not protected by strict required checks"
        )
    contexts = {
        str(context)
        for context in (required.get("contexts") or [])
        if isinstance(context, str) and context
    }
    for check in required.get("checks") or []:
        if isinstance(check, Mapping) and isinstance(check.get("context"), str):
            contexts.add(str(check["context"]))
    if not contexts:
        raise DeliveryError(
            f"GitHub branch {branch!r} has no required status checks"
        )

    checks_payload = api_get(
        f"repos/{GITHUB_REPOSITORY}/commits/{sha}/check-runs?per_page=100"
    )
    newest: dict[str, Mapping[str, Any]] = {}
    for check_run in checks_payload.get("check_runs", []):
        if not isinstance(check_run, Mapping):
            continue
        name = check_run.get("name")
        if not isinstance(name, str):
            continue
        current = newest.get(name)
        current_id = current.get("id", -1) if current else -1
        candidate_id = check_run.get("id", -1)
        if not isinstance(current_id, int):
            current_id = -1
        if not isinstance(candidate_id, int):
            candidate_id = -1
        if candidate_id > current_id:
            newest[name] = check_run

    accepted = {"success", "neutral", "skipped"}
    for context in sorted(contexts):
        check_run = newest.get(context)
        if check_run is None:
            raise DeliveryError(
                f"required GitHub check {context!r} is missing for {sha[:12]}"
            )
        if (
            str(check_run.get("status", "")).lower() != "completed"
            or str(check_run.get("conclusion", "")).lower() not in accepted
        ):
            raise DeliveryError(
                f"required GitHub check {context!r} is not green for {sha[:12]}"
            )
    return sha


class AppStoreConnectClient:
    """Minimal JSON client. Authorization values are never included in errors."""

    def __init__(
        self,
        token_provider: Callable[[], str],
        *,
        opener: Callable[..., Any] | None = None,
    ) -> None:
        self._token_provider = token_provider
        self._opener = urllib.request.urlopen if opener is None else opener

    def request(
        self,
        method: str,
        path: str,
        body: Mapping[str, Any] | None = None,
    ) -> Mapping[str, Any]:
        url = path if path.startswith("https://") else f"{API_BASE}{path}"
        payload = None
        if body is not None:
            payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(url, data=payload, method=method)
        # A cloud build can run longer than Apple's 20-minute JWT limit. Mint a
        # fresh short-lived token for each poll rather than letting monitoring
        # fail partway through a valid build.
        request.add_header(
            "Authorization", f"Bearer {self._token_provider()}"
        )
        request.add_header("Accept", "application/json")
        if payload is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with self._opener(
                request, timeout=REQUEST_TIMEOUT_SECONDS
            ) as response:
                parsed = json.loads(response.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as error:
            raise DeliveryError(
                f"App Store Connect returned HTTP {error.code} for "
                f"{method} {urllib.parse.urlparse(url).path}; check the API "
                "key role and Xcode Cloud setup"
            ) from None
        except urllib.error.URLError as error:
            raise DeliveryError(
                f"cannot reach App Store Connect: {error.reason}"
            ) from None
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise DeliveryError(
                "App Store Connect returned an unreadable response"
            ) from None
        if not isinstance(parsed, Mapping):
            raise DeliveryError("App Store Connect returned an invalid response")
        return parsed


def _resource_list(
    payload: Mapping[str, Any], resource_name: str
) -> list[Mapping[str, Any]]:
    data = payload.get("data")
    if not isinstance(data, list):
        raise DeliveryError(
            f"App Store Connect returned an invalid {resource_name} response"
        )
    return [item for item in data if isinstance(item, Mapping)]


def resolve_product(
    client: Any, *, bundle_id: str = BUNDLE_ID
) -> tuple[str, str]:
    payload = client.request("GET", "/ciProducts?include=app&limit=200")
    app_ids = {
        item.get("id")
        for item in payload.get("included", [])
        if isinstance(item, Mapping)
        and item.get("type") == "apps"
        and (item.get("attributes") or {}).get("bundleId") == bundle_id
    }
    matches: list[tuple[str, str]] = []
    for product in _resource_list(payload, "Xcode Cloud products"):
        app = ((product.get("relationships") or {}).get("app") or {}).get("data")
        if isinstance(app, Mapping) and app.get("id") in app_ids:
            matches.append((str(product.get("id")), str(app.get("id"))))
    if not matches:
        raise DeliveryError(
            f"Xcode Cloud product is missing: create the standalone Recall "
            f"product for bundle ID {bundle_id} in Xcode"
        )
    if len(matches) > 1:
        raise DeliveryError(
            f"multiple Xcode Cloud products use bundle ID {bundle_id}; remove "
            "or relink the duplicate before shipping"
        )
    return matches[0]


def resolve_workflow(
    client: Any, *, product_id: str, workflow_name: str
) -> str:
    payload = client.request(
        "GET", f"/ciProducts/{product_id}/workflows?limit=200"
    )
    matches = [
        item
        for item in _resource_list(payload, "Xcode Cloud workflows")
        if (item.get("attributes") or {}).get("name") == workflow_name
    ]
    if not matches:
        raise DeliveryError(
            f"Xcode Cloud workflow is missing: create an enabled manual "
            f"workflow named {workflow_name!r} for the standalone Recall product"
        )
    if len(matches) > 1:
        raise DeliveryError(
            f"multiple Xcode Cloud workflows are named {workflow_name!r}; "
            "rename the duplicate before shipping"
        )
    workflow = matches[0]
    if (workflow.get("attributes") or {}).get("isEnabled") is False:
        raise DeliveryError(
            f"Xcode Cloud workflow {workflow_name!r} is disabled: enable it "
            "in App Store Connect before shipping"
        )
    return str(workflow.get("id"))


def resolve_reference(
    client: Any, *, product_id: str, branch: str
) -> tuple[str, str]:
    repositories = client.request(
        "GET", f"/ciProducts/{product_id}/primaryRepositories?limit=200"
    )
    repository_items = _resource_list(
        repositories, "Xcode Cloud primary repositories"
    )
    matches = [
        item
        for item in repository_items
        if (
            (item.get("attributes") or {}).get("ownerName") == "s0673468"
            and (item.get("attributes") or {}).get("repositoryName") == "Recall"
        )
    ]
    if not matches and len(repository_items) == 1:
        # Older API versions can omit repository attributes unless requested.
        matches = repository_items
    if len(matches) != 1:
        raise DeliveryError(
            "Xcode Cloud repository is missing or ambiguous: connect "
            "github.com/s0673468/Recall as the standalone product's primary "
            "repository"
        )
    repository_id = str(matches[0].get("id"))
    references = client.request(
        "GET",
        f"/scmRepositories/{repository_id}/gitReferences?limit=200",
    )
    matches = []
    for item in _resource_list(references, "Xcode Cloud git references"):
        attributes = item.get("attributes") or {}
        if (
            attributes.get("kind") == "BRANCH"
            and attributes.get("name") == branch
            and attributes.get("isDeleted") is not True
        ):
            matches.append(str(item.get("id")))
    if len(matches) != 1:
        raise DeliveryError(
            f"Xcode Cloud branch reference is missing or ambiguous: push "
            f"branch {branch!r} to github.com/s0673468/Recall and refresh the "
            "standalone product's repository access"
        )
    return repository_id, matches[0]


def resolve_target(
    client: Any, *, workflow_name: str, branch: str
) -> BuildTarget:
    product_id, app_id = resolve_product(client)
    workflow_id = resolve_workflow(
        client, product_id=product_id, workflow_name=workflow_name
    )
    repository_id, reference_id = resolve_reference(
        client, product_id=product_id, branch=branch
    )
    return BuildTarget(
        app_id=app_id,
        product_id=product_id,
        workflow_id=workflow_id,
        workflow_name=workflow_name,
        repository_id=repository_id,
        reference_id=reference_id,
        branch=branch,
    )


def build_run_body(target: BuildTarget) -> dict[str, Any]:
    return {
        "data": {
            "type": "ciBuildRuns",
            "attributes": {"clean": False},
            "relationships": {
                "workflow": {
                    "data": {
                        "type": "ciWorkflows",
                        "id": target.workflow_id,
                    }
                },
                "sourceBranchOrTag": {
                    "data": {
                        "type": "scmGitReferences",
                        "id": target.reference_id,
                    }
                },
            },
        }
    }


def _build_state(payload: Mapping[str, Any]) -> tuple[str, Any, str, Any]:
    data = payload.get("data")
    if not isinstance(data, Mapping) or not data.get("id"):
        raise DeliveryError(
            "App Store Connect returned an invalid Xcode Cloud build response"
        )
    attributes = data.get("attributes") or {}
    return (
        str(data["id"]),
        attributes.get("number"),
        str(attributes.get("executionProgress") or "UNKNOWN").upper(),
        attributes.get("completionStatus"),
    )


def start_build(client: Any, target: BuildTarget) -> Mapping[str, Any]:
    return client.request("POST", "/ciBuildRuns", build_run_body(target))


def poll_build(
    client: Any,
    initial_payload: Mapping[str, Any],
    *,
    output: TextIO,
    sleep: Callable[[float], None] = time.sleep,
    poll_interval: float = DEFAULT_POLL_INTERVAL_SECONDS,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    expected_sha: str | None = None,
    monotonic: Callable[[], float] = time.monotonic,
) -> str:
    payload = initial_payload
    last_display: tuple[Any, str, Any] | None = None
    deadline = monotonic() + timeout
    while True:
        run_id, number, progress, completion = _build_state(payload)
        display = (number, progress, completion)
        if display != last_display:
            suffix = f", completion {completion}" if completion else ""
            print(
                f"Build {number if number is not None else 'pending number'}: "
                f"execution {progress}{suffix}",
                file=output,
            )
            last_display = display
        if progress == TERMINAL_PROGRESS:
            if not completion:
                raise DeliveryError(
                    "Xcode Cloud marked the build complete without a completion "
                    "status"
                )
            completion_status = str(completion).upper()
            if completion_status == SUCCESS_STATUS and expected_sha is not None:
                data = payload.get("data")
                attributes = (
                    data.get("attributes") if isinstance(data, Mapping) else {}
                )
                source_commit = (
                    attributes.get("sourceCommit")
                    if isinstance(attributes, Mapping)
                    else None
                )
                source_sha = (
                    source_commit.get("commitSha")
                    if isinstance(source_commit, Mapping)
                    else None
                )
                if source_sha != expected_sha:
                    raise DeliveryError(
                        "Xcode Cloud built a different commit than the protected "
                        f"GitHub tip {expected_sha[:12]}"
                    )
            return completion_status
        if monotonic() >= deadline:
            raise DeliveryError(
                f"timed out waiting for Xcode Cloud build "
                f"{number if number is not None else run_id}"
            )
        sleep(poll_interval)
        payload = client.request(
            "GET",
            f"/ciBuildRuns/{run_id}?fields[ciBuildRuns]="
            "number,executionProgress,completionStatus,sourceCommit,finishedDate",
        )


def poll_testflight(
    client: Any,
    *,
    run_id: str,
    target: BuildTarget,
    output: TextIO,
    sleep: Callable[[float], None] = time.sleep,
    poll_interval: float = DEFAULT_POLL_INTERVAL_SECONDS,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    monotonic: Callable[[], float] = time.monotonic,
) -> str:
    """Wait for a VALID build attached to Recall's internal tester group."""
    deadline = monotonic() + timeout
    last_state: str | None = None
    builds_path = (
        f"/ciBuildRuns/{run_id}/builds?"
        "fields[builds]=version,processingState,usesNonExemptEncryption"
    )
    while True:
        builds = _resource_list(
            client.request("GET", builds_path),
            "TestFlight builds",
        )
        if len(builds) > 1:
            raise DeliveryError(
                "Xcode Cloud returned more than one TestFlight build for the run"
            )
        if builds:
            build = builds[0]
            attributes = build.get("attributes") or {}
            processing = str(
                attributes.get("processingState") or "PROCESSING"
            ).upper()
            if processing != last_state:
                print(f"TestFlight processing: {processing}", file=output)
                last_state = processing
            if processing in {"FAILED", "INVALID"}:
                raise DeliveryError(
                    f"TestFlight build processing finished with {processing}"
                )
            if processing == "VALID":
                if attributes.get("usesNonExemptEncryption") is not False:
                    raise DeliveryError(
                        "TestFlight build lacks the source-controlled "
                        "non-exempt-encryption declaration"
                    )
                build_id = build.get("id")
                if not isinstance(build_id, str) or not build_id:
                    raise DeliveryError(
                        "App Store Connect returned an invalid TestFlight build"
                    )
                group_query = urllib.parse.urlencode(
                    {
                        "filter[app]": target.app_id,
                        "filter[name]": TESTFLIGHT_GROUP,
                        "filter[isInternalGroup]": "true",
                        "filter[builds]": build_id,
                        "limit": 200,
                    }
                )
                groups = _resource_list(
                    client.request("GET", f"/betaGroups?{group_query}"),
                    "TestFlight beta groups",
                )
                exact_groups = [
                    group
                    for group in groups
                    if (group.get("attributes") or {}).get("name")
                    == TESTFLIGHT_GROUP
                    and (group.get("attributes") or {}).get("isInternalGroup")
                    is True
                ]
                if len(exact_groups) > 1:
                    raise DeliveryError(
                        f"multiple internal TestFlight groups are named "
                        f"{TESTFLIGHT_GROUP!r}"
                    )
                if len(exact_groups) == 1:
                    version = attributes.get("version") or build_id
                    print(
                        f"TestFlight build {version} is VALID and attached to "
                        f"internal group {TESTFLIGHT_GROUP}.",
                        file=output,
                    )
                    return build_id
        if monotonic() >= deadline:
            raise DeliveryError(
                "timed out waiting for a VALID TestFlight build attached to "
                f"internal group {TESTFLIGHT_GROUP}"
            )
        sleep(poll_interval)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Start Recall's Xcode Cloud workflow and wait for it to finish. "
            "Requires ASC_KEY_ID and ASC_ISSUER_ID. The private key must be at "
            "~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8."
        )
    )
    parser.add_argument(
        "--workflow",
        default=DEFAULT_WORKFLOW,
        help=f"exact workflow name (default: {DEFAULT_WORKFLOW!r})",
    )
    parser.add_argument(
        "--branch",
        default=DEFAULT_BRANCH,
        help=f"branch to build (default: {DEFAULT_BRANCH!r})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "resolve the product, workflow, and branch reference without "
            "starting a build"
        ),
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL_SECONDS,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=argparse.SUPPRESS,
    )
    return parser


def run(
    argv: list[str] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    home: Path | None = None,
    client_factory: Callable[[Callable[[], str]], Any] = AppStoreConnectClient,
    release_gate: Callable[[str], str] = verify_github_release,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    issued_at: int | None = None,
    output: TextIO | None = None,
    error_output: TextIO | None = None,
) -> int:
    args = make_parser().parse_args(argv)
    output = sys.stdout if output is None else output
    error_output = sys.stderr if error_output is None else error_output
    active_environment = os.environ if environ is None else environ
    active_home = Path.home() if home is None else home
    try:
        if args.poll_interval <= 0 or args.timeout <= 0:
            raise DeliveryError("--poll-interval and --timeout must be positive")
        gated_sha = release_gate(args.branch)
        credentials = credentials_from_environment(
            active_environment, home=active_home
        )
        token_provider = lambda: mint_jwt(
            credentials, issued_at=issued_at
        )
        client = client_factory(token_provider)
        target = resolve_target(
            client, workflow_name=args.workflow, branch=args.branch
        )
        print(
            f"Resolved product {target.product_id}, workflow "
            f"{target.workflow_name!r} ({target.workflow_id}), and branch "
            f"{target.branch!r} ({target.reference_id}).",
            file=output,
        )
        if args.dry_run:
            print(
                f"Dry run: protected GitHub tip {gated_sha[:12]} is green; "
                "no Xcode Cloud build was started.",
                file=output,
            )
            return 0

        if release_gate(args.branch) != gated_sha:
            raise DeliveryError(
                f"GitHub branch {args.branch!r} moved after target resolution; "
                "run the command again"
            )
        initial = start_build(client, target)
        run_id, _, _, _ = _build_state(initial)
        completion = poll_build(
            client,
            initial,
            output=output,
            sleep=sleep,
            poll_interval=args.poll_interval,
            timeout=args.timeout,
            expected_sha=gated_sha,
            monotonic=monotonic,
        )
        if completion != SUCCESS_STATUS:
            return 1
        poll_testflight(
            client,
            run_id=run_id,
            target=target,
            output=output,
            sleep=sleep,
            poll_interval=args.poll_interval,
            timeout=args.timeout,
            monotonic=monotonic,
        )
        return 0
    except DeliveryError as error:
        print(f"error: {error}", file=error_output)
        return 1


def main() -> int:
    return run()


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Conservative, offline iteration checks; CI remains the complete delivery gate."""
import argparse
import json
import os
from pathlib import Path
import posixpath
import re
import shlex
import subprocess
import sys
import time

PYTHON_SUITES = (
    "tool/tests", "web/tool/tests", "scripts/tests",
    "tools/recall_sync/tests", "tools/anki_revision/tests",
    "tools/semantic_review/tests", "tools/flag_report/tests",
    "tools/fsrs_optimize/tests",
)
NOTICE = "Iteration checks only; not a merge gate. Run the complete required CI on the final head."
PYTHON_WRAPPERS = {
    "tools/semantic_review/tests": "test/semantic_review_tool_test.dart",
    "tools/flag_report/tests": "test/flag_report_test.dart",
    "scripts/tests": "test/testflight_build_script_test.dart",
}


def changed_files(root, base):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE).decode().split("\0")
    merge_base = git("merge-base", base, "HEAD")[0].strip()
    files = set()
    # Separate diffs retain staged changes cancelled by an unstaged edit. --no-renames
    # includes both sides of a move, even when the old module no longer exists.
    for args in [("diff", "--name-only", "--no-renames", "-z", merge_base, "HEAD"),
                 ("diff", "--cached", "--name-only", "--no-renames", "-z"),
                 ("diff", "--name-only", "--no-renames", "-z"),
                 ("ls-files", "--others", "--exclude-standard", "-z")]:
        files.update(x for x in git(*args) if x)
    return sorted(files)


def dart_tests(root, changed):
    tests = sorted(p.relative_to(root).as_posix() for p in (root / "test").rglob("*_test.dart"))
    graph = {}
    contracts = set()
    for folder in ("lib", "test"):
        for path in (root / folder).rglob("*.dart"):
            name = path.relative_to(root).as_posix()
            source = path.read_text()
            graph[name] = set()
            if "dart:io" in source and name in tests and name not in PYTHON_WRAPPERS.values():
                contracts.add(name)  # File-based contracts don't have Dart import edges.
            # Include every URI in import/export/part directives, including conditional
            # imports. False positives broaden selection; they cannot omit a consumer.
            for directive in re.findall(r"\b(?:import|export|part)\s+[^;]+;", source):
                for uri in re.findall(r"['\"]([^'\"]+)['\"]", directive):
                    prefix = "package:health_anki_flutter/"
                    if uri.startswith(prefix):
                        graph[name].add("lib/" + uri[len(prefix):])
                    elif ":" not in uri:
                        graph[name].add(posixpath.normpath(posixpath.join(posixpath.dirname(name), uri)))
    affected = set(changed)
    while True:
        consumers = {name for name, deps in graph.items() if deps & affected}
        if consumers <= affected:
            break
        affected.update(consumers)
    selected = set(tests) & affected
    # An unreferenced/new module or deleted test cannot establish a safe narrow set.
    for change in changed:
        reach = {change}
        while True:
            more = {name for name, deps in graph.items() if deps & reach}
            if more <= reach:
                break
            reach.update(more)
        if not (set(tests) & reach):
            return ["test"]
    return sorted(selected | contracts)


def plan(root, paths):
    paths = sorted(set(paths))
    result = {"notice": NOTICE, "paths": paths, "full": False,
              "flutter_tests": [], "python_suites": [], "native_lanes": [], "web_build": False}
    dart = []
    python = set()
    native = set()
    broad_flutter = False
    for path in paths:
        if path in ("README.md", "IOS_SETUP.md", "ANDROID_SETUP.md") or path.startswith("docs/") and path.endswith(".md"):
            continue
        if path.startswith(("lib/", "test/")) and path.endswith(".dart"):
            dart.append(path)
        elif path.startswith("ios/"):
            native.add("ios")
            broad_flutter = True
        elif path.startswith("android/"):
            native.add("android")
            broad_flutter = True
        elif path.startswith("web/"):
            python.add("web/tool/tests")
            broad_flutter = True
            result["web_build"] = True
        elif path in ("tool/run_ios_tests.py", "tool/check_android_release_policy.py"):
            native.add("ios" if "ios" in path else "android")
            python.add("tool/tests")
            broad_flutter = True
        elif path.endswith(".py") and path != "tool/affected_tests.py":
            matches = [suite for suite in PYTHON_SUITES if path.startswith(suite.rsplit("/", 1)[0] + "/")]
            if not matches:
                result["full"] = True
            python.update(matches)
        else:
            result["full"] = True
    if result["full"]:
        result.update(flutter_tests=["test"], python_suites=list(PYTHON_SUITES), native_lanes=["android", "ios"], web_build=True)
    else:
        result["flutter_tests"] = ["test"] if broad_flutter else dart_tests(root, dart) if dart else []
        result["python_suites"] = sorted(python)
        result["native_lanes"] = sorted(native)
    return result


def commands(selection, lane, concurrency):
    steps = []
    if lane in ("portable", "all"):
        if selection["flutter_tests"]:
            steps.extend([
                ["./tool/flutterw", "analyze", "--no-pub"],
                ["./tool/flutterw", "test", "--no-pub", "--reporter=failures-only", f"--concurrency={concurrency}", *selection["flutter_tests"]],
            ])
        # These Python suites are already run by their Dart wrapper in a broad
        # Flutter run. Keep standalone suites only when the wrapper is absent.
        for suite in selection["python_suites"]:
            if suite in PYTHON_WRAPPERS and (selection["flutter_tests"] == ["test"] or PYTHON_WRAPPERS[suite] in selection["flutter_tests"]):
                continue
            steps.append([sys.executable, "-m", "unittest", "discover", "-s", suite, "-p", "test_*.py"])
        if selection["web_build"]:
            steps.append(["./tool/flutterw", "build", "web", "--release", "--no-pub", "--base-href", "/Recall/", "--no-web-resources-cdn"])
    if lane in ("android", "all") and "android" in selection["native_lanes"]:
        steps.extend([
            ["./tool/flutterw", "build", "apk", "--debug", "--no-pub"],
            [sys.executable, "tool/check_android_release_policy.py"],
            ["android/gradlew", "-p", "android", ":app:testDebugUnitTest", ":app:lintDebug", ":app:assembleDebugAndroidTest", "--no-daemon", "--max-workers=2"],
        ])
    if lane in ("ios", "all") and "ios" in selection["native_lanes"]:
        steps.extend([
            ["./tool/flutterw", "build", "ios", "--debug", "--simulator", "--config-only", "--no-codesign", "--no-pub"],
            [sys.executable, "tool/run_ios_tests.py", "--", "-workspace", "ios/Runner.xcworkspace", "-scheme", "Runner", "-configuration", "Debug", "CODE_SIGNING_ALLOWED=NO"],
        ])
    return steps


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main", help="branch-point reference; committed and dirty changes are combined")
    parser.add_argument("--path", action="append", default=[], help="additional path to include; never excludes detected changes")
    parser.add_argument("--all", action="store_true", help="select all suites, still an iteration plan")
    parser.add_argument("--lane", choices=("portable", "android", "ios", "all"), default="portable")
    parser.add_argument("--concurrency", type=int, default=int(os.environ.get("FLEET_CI_CPU_BUDGET", "2")))
    parser.add_argument("--run", action="store_true", help="execute this lane, using already installed dependencies")
    args = parser.parse_args(argv)
    if args.concurrency < 1:
        parser.error("concurrency must be positive")
    root = Path(__file__).resolve().parents[1]
    try:
        paths = changed_files(root, args.base)
        reason = None
    except subprocess.CalledProcessError:
        paths = ["<unknown-base>"]
        reason = "Cannot establish the Git base; selecting all suites."
    selection = plan(root, paths + args.path + (["<all>"] if args.all else []))
    selection["reason"] = reason
    selection["lane"] = args.lane
    selection["deferred_native_lanes"] = [x for x in selection["native_lanes"] if args.lane not in (x, "all")]
    selection["commands"] = commands(selection, args.lane, args.concurrency)
    print(json.dumps(selection, indent=2), flush=True)
    if not args.run:
        return 0
    for command in selection["commands"]:
        print("Running " + shlex.join(command), flush=True)
        started = time.monotonic()
        status = subprocess.run(command, cwd=root).returncode
        print(json.dumps({"command": command, "seconds": round(time.monotonic() - started, 3), "exit_status": status}), flush=True)
        if status:
            return status
    print(NOTICE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run XCTest serially on a disposable simulator owned by this invocation."""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import uuid


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


def cancel(signum, _frame):
    raise Cancelled(signum)


def select_device(payload, name=None):
    runtimes = sorted(payload["devices"], key=lambda value: tuple(
        int(part) for part in re.findall(r"\d+", value)), reverse=True)
    for runtime in runtimes:
        if ".iOS-" not in runtime:
            continue
        for device in payload["devices"][runtime]:
            if (device.get("isAvailable") and device["name"].startswith("iPhone")
                    and (name is None or device["name"] == name)):
                return device["deviceTypeIdentifier"], runtime
    raise RuntimeError("No matching available iPhone simulator was found")


def run_build(arguments):
    process = subprocess.Popen(arguments, start_new_session=True)
    try:
        return process.wait()
    except BaseException:
        # Stop only our build process group before removing its simulator.
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        raise


def run_tests(arguments, device_name=None):
    if any(arg in arguments for arg in ("-destination", "-parallel-testing-enabled")):
        raise ValueError("The test helper owns simulator destination and parallelism")
    payload = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    device_type, runtime = select_device(payload, device_name)
    device_id = ""
    result = 1
    previous = signal.signal(signal.SIGTERM, cancel)
    try:
        created = subprocess.check_output(
            ["xcrun", "simctl", "create", f"XCTest-{uuid.uuid4()}", device_type, runtime],
            text=True).strip()
        device_id = str(uuid.UUID(created))
        result = run_build([
            "xcodebuild", "test", *arguments,
            "-destination", f"platform=iOS Simulator,id={device_id}",
            "-parallel-testing-enabled", "NO",
        ])
    finally:
        try:
            if device_id:
                subprocess.run(["xcrun", "simctl", "shutdown", device_id],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                deleted = subprocess.run(["xcrun", "simctl", "delete", device_id])
                if deleted.returncode:
                    print(f"Could not delete this run's simulator {device_id}", file=sys.stderr)
                    result = result or deleted.returncode
        finally:
            signal.signal(signal.SIGTERM, previous)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-name")
    parser.add_argument("xcodebuild_arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.xcodebuild_arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if not arguments:
        parser.error("pass xcodebuild options after --")
    try:
        return run_tests(arguments, args.device_name)
    except Cancelled as exc:
        return 128 + exc.signum


if __name__ == "__main__":
    raise SystemExit(main())

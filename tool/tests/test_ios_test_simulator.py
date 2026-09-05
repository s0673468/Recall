"""The test runner owns and removes one simulator without touching shared devices."""

import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "run_ios_tests.py"
spec = importlib.util.spec_from_file_location("run_ios_tests", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

DEVICE_ID = "00000000-1111-4222-8333-444444444444"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
PAYLOAD = {"devices": {RUNTIME: [{"name": "iPhone 17 Pro", "isAvailable": True,
                                 "deviceTypeIdentifier": TYPE}]}}


class SimulatorLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.capture = patch.object(runner.subprocess, "check_output",
                                    side_effect=[json.dumps(PAYLOAD), DEVICE_ID + "\n"])
        self.check_output = self.capture.start()
        self.addCleanup(self.capture.stop)
        self.commands = patch.object(runner.subprocess, "run",
                                     return_value=Mock(returncode=0))
        self.command = self.commands.start()
        self.addCleanup(self.commands.stop)
        self.build = patch.object(runner, "run_build", return_value=0)
        self.run_build = self.build.start()
        self.addCleanup(self.build.stop)

    def test_serial_test_uses_and_deletes_only_the_created_device(self):
        self.assertEqual(runner.run_tests(["-scheme", "Runner"], "iPhone 17 Pro"), 0)
        created = self.check_output.call_args_list[1].args[0]
        self.assertEqual(created[:3], ["xcrun", "simctl", "create"])
        self.assertEqual(created[-2:], [TYPE, RUNTIME])
        self.assertEqual(self.run_build.call_args.args[0], [
            "xcodebuild", "test", "-scheme", "Runner", "-destination",
            f"platform=iOS Simulator,id={DEVICE_ID}", "-parallel-testing-enabled", "NO"])
        self.assertEqual([call.args[0] for call in self.command.call_args_list], [
            ["xcrun", "simctl", "shutdown", DEVICE_ID],
            ["xcrun", "simctl", "delete", DEVICE_ID]])

    def test_failing_build_is_preserved_and_owned_device_is_removed(self):
        self.run_build.return_value = 65
        self.assertEqual(runner.run_tests(["-scheme", "Runner"]), 65)
        self.assertEqual(self.command.call_args.args[0], ["xcrun", "simctl", "delete", DEVICE_ID])

    def test_cancelled_build_still_removes_owned_device(self):
        self.run_build.side_effect = runner.Cancelled(signal.SIGTERM)
        with self.assertRaises(runner.Cancelled):
            runner.run_tests(["-scheme", "Runner"])
        self.assertEqual(self.command.call_args.args[0], ["xcrun", "simctl", "delete", DEVICE_ID])

    def test_failed_creation_never_deletes_an_existing_device(self):
        self.check_output.side_effect = [json.dumps(PAYLOAD), subprocess.CalledProcessError(1, "create")]
        with self.assertRaises(subprocess.CalledProcessError):
            runner.run_tests(["-scheme", "Runner"])
        self.command.assert_not_called()
        self.run_build.assert_not_called()

    def test_cleanup_failure_is_visible_even_when_tests_pass(self):
        self.command.side_effect = [Mock(returncode=0), Mock(returncode=1)]
        self.assertEqual(runner.run_tests(["-scheme", "Runner"]), 1)

    def test_destination_override_is_rejected_before_device_creation(self):
        with self.assertRaises(ValueError):
            runner.run_tests(["-destination", "id=shared"])
        self.check_output.assert_not_called()

    def test_no_matching_device_does_not_create_or_delete_anything(self):
        with self.assertRaises(RuntimeError):
            runner.run_tests(["-scheme", "Runner"], "iPhone 99")
        self.assertEqual(self.check_output.call_count, 1)
        self.command.assert_not_called()


class BuildCancellationTests(unittest.TestCase):
    def test_cancellation_waits_for_own_build_before_cleanup(self):
        process = Mock(pid=123)
        process.wait.side_effect = [KeyboardInterrupt, 143]
        process.poll.return_value = None
        with patch.object(runner.subprocess, "Popen", return_value=process), \
                patch.object(runner.os, "killpg") as kill:
            with self.assertRaises(KeyboardInterrupt):
                runner.run_build(["xcodebuild", "test"])
        kill.assert_called_once_with(123, signal.SIGTERM)
        self.assertEqual(process.wait.call_count, 2)


if __name__ == "__main__":
    unittest.main()

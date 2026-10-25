"""Execute the maintained CI shell against synthetic files and a fake Flutter.

No SDK, accounts, network, or hosted runner is involved. These tests exercise
the workflow's actual commands, including its failure handling.
"""
import itertools
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text()


def job(name):
    return re.split(r"\n  [a-z0-9-]+:\n", WORKFLOW.split(f"\n  {name}:\n", 1)[1])[0]


def step(block, name):
    lines = block.split(f"      - name: {name}\n", 1)[1].splitlines()
    for index, line in enumerate(lines):
        if line.startswith("        run: "):
            command = line.removeprefix("        run: ")
            if command != "|":
                return command
            body = []
            for line in lines[index + 1:]:
                if line and not line.startswith("          "):
                    break
                body.append(line[10:])
            return "\n".join(body)
    raise AssertionError(f"No run command for {name}")


class CiGateExecutionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "tool").mkdir()
        self.flutter = self.root / "tool/flutterw"
        self.flutter.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        self.flutter.chmod(0o755)
        shutil.copy2(ROOT / "tool/flutter_test_shards.py", self.root / "tool")
        self.files = []
        for index in range(21):
            name = f"test/nested/case_{index:02d}_test.dart"
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// synthetic\n" * (index + 1))
            self.files.append(name)

    def run_shell(self, command, **environment):
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", command],
            cwd=self.root, env={**os.environ, **environment},
            capture_output=True, text=True, timeout=10,
        )

    def test_four_hosted_shards_run_every_file_once(self):
        block = job("flutter-tests")
        total = int(re.search(r"SHARD_TOTAL: (\d+)", block)[1])
        indices = [int(value) for value in re.search(r"shard: \[([\d, ]+)\]", block)[1].split(",")]
        self.assertEqual(total, 4)
        self.assertEqual(indices, list(range(total)))
        collected = []
        command = step(block, "flutter test (file shard)")
        for index in indices:
            with self.subTest(index=index):
                result = self.run_shell(command, SHARD_TOTAL=str(total), SHARD_INDEX=str(index))
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = result.stdout.splitlines()
                self.assertEqual(arguments[:6], [
                    "test", "--reporter=failures-only", "--exclude-tags",
                    "apple-mobile", "--no-pub", "--concurrency=4",
                ])
                self.assertTrue(arguments[6:], "An empty shard would run the whole suite")
                collected.extend(arguments[6:])
        self.assertEqual(sorted(collected), self.files)

    def test_failed_listing_never_launches_flutter_and_failed_tests_fail_the_job(self):
        command = step(job("flutter-tests"), "flutter test (file shard)")
        refused = self.run_shell(command, SHARD_TOTAL="22", SHARD_INDEX="0")
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(refused.stdout, "")
        self.assertIn("leaves a shard empty", refused.stderr)

        self.flutter.write_text("#!/bin/sh\nexit 23\n")
        failed = self.run_shell(command, SHARD_TOTAL="4", SHARD_INDEX="0")
        self.assertEqual(failed.returncode, 23)

    def test_required_flutter_gate_accepts_only_success_from_both_dependencies(self):
        command = step(job("flutter"), "Require Flutter checks and every test shard")
        for checks, tests in itertools.product(("success", "failure", "cancelled", "skipped"), repeat=2):
            with self.subTest(checks=checks, tests=tests):
                result = self.run_shell(command, CHECKS_RESULT=checks, TESTS_RESULT=tests)
                self.assertEqual(result.returncode == 0, checks == tests == "success")

    def test_analysis_reuses_the_preceding_pub_get(self):
        result = self.run_shell(step(job("flutter-checks"), "flutter analyze"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["analyze", "--no-pub"])

    def test_cpu_optimizer_install_preserves_requirements_and_fails_closed(self):
        python = self.root / "tool/python"
        python.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\nexit "${FAKE_PIP_STATUS:-0}"\n')
        python.chmod(0o755)
        command = step(job("fsrs-optimizer"), "Install FSRS optimizer dependencies")
        path = str(python.parent) + os.pathsep + os.environ["PATH"]
        expected = [
            "-m pip install torch --index-url https://download.pytorch.org/whl/cpu",
            "-m pip install -r tools/fsrs_optimize/requirements.txt",
        ]
        result = self.run_shell(command, PATH=path, FAKE_PIP_STATUS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), expected)
        refused = self.run_shell(command, PATH=path, FAKE_PIP_STATUS="23")
        self.assertEqual(refused.returncode, 23)
        self.assertEqual(refused.stdout.splitlines(), expected[:1])


if __name__ == "__main__":
    unittest.main()

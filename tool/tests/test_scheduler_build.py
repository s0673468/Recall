"""Compile the real scheduler and validate synthetic VM/JS parity in CI."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SharedSchedulerBuildTest(unittest.TestCase):
    def test_compiled_engine_matches_every_synthetic_vm_vector(self):
        node = shutil.which("node")
        dart = os.environ.get("DART") or shutil.which("dart")
        self.assertIsNotNone(node, "Node is required for the compiled scheduler gate")
        self.assertIsNotNone(dart, "Use Dart from Recall's pinned Flutter SDK")
        with tempfile.TemporaryDirectory(prefix="recall-scheduler-") as output:
            env = {**os.environ, "DART": dart}
            result = subprocess.run(
                [node, "tool/scheduler/build.mjs", output], cwd=ROOT,
                env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            verified = subprocess.run(
                [node, "tool/scheduler/differential.mjs", output], cwd=ROOT,
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
            self.assertIn("34623/34623 vectors matched (100%)", verified.stdout)
            self.assertLess(Path(output, "engine.mjs").stat().st_size, 150000)


if __name__ == "__main__":
    unittest.main()

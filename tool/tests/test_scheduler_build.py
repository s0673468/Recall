"""Compile the real scheduler and validate synthetic VM/JS parity in CI."""
import json
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
        numeric = subprocess.run(
            [node, "--test", "tool/scheduler/numeric_math.test.mjs"], cwd=ROOT,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(numeric.returncode, 0, numeric.stdout + numeric.stderr)
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
            proof = json.loads(Path(output, "provenance.json").read_text())
            self.assertEqual(proof["vectors"], 34623)
            self.assertEqual(proof["matched"], proof["vectors"])
            self.assertEqual(proof["matchRatio"], 1)
            self.assertTrue(proof["verified"])
            self.assertEqual(proof["numericAdapterAlgorithm"], "double-double-small-exp/v1")
            self.assertEqual(proof["historyStates"], "0,1,2,3")
            self.assertEqual(proof["historyRatings"], "1,2,3,4")
            self.assertGreater(proof["historyLapseTransitions"], 0)
            self.assertEqual(proof["dueDates"], "exact")
            self.assertEqual(proof["verified"], proof["matched"] == proof["vectors"])
            # No test exclusions or tolerance changes: strict parity must pass.
            strict = subprocess.run(
                [node, "tool/scheduler/differential.mjs", output], cwd=ROOT,
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(strict.returncode == 0, proof["verified"])
            if not proof["verified"]:
                self.assertIn("grading disabled", strict.stderr)
            self.assertLess(Path(output, "engine.mjs").stat().st_size, 150000)


if __name__ == "__main__":
    unittest.main()

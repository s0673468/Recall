from pathlib import Path
import shutil
import subprocess
import unittest


class ServiceWorkerTests(unittest.TestCase):
    def test_versioned_cache_behavior(self) -> None:
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node.js is required for service-worker tests")
        result = subprocess.run(
            [node, "--test", str(Path(__file__).with_name("service_worker.test.cjs"))],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

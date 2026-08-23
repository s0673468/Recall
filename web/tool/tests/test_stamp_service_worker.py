from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "stamp_service_worker.py"
SPEC = importlib.util.spec_from_file_location("stamp_service_worker", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
stamp_service_worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stamp_service_worker)


class StampServiceWorkerTests(unittest.TestCase):
    def test_worker_keeps_cache_writes_inside_the_fetch_lifetime(self) -> None:
        worker = SCRIPT.parents[1] / "sw.js"

        self.assertIn(
            "await cache.put(request, response.clone())",
            worker.read_text(encoding="utf-8"),
        )

    def test_stamps_exactly_one_version_and_removes_flutter_tombstone(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            worker = output / "sw.js"
            worker.write_text("const VERSION = '__SW_VERSION__';\n", encoding="utf-8")
            tombstone = output / "flutter_service_worker.js"
            tombstone.write_text("", encoding="utf-8")
            version = "a" * 40

            stamp_service_worker.finish_build(output, version)

            self.assertEqual(
                worker.read_text(encoding="utf-8"),
                f"const VERSION = '{version}';\n",
            )
            self.assertFalse(tombstone.exists())

    def test_rejects_an_invalid_version_without_changing_the_worker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            worker = output / "sw.js"
            original = "const VERSION = '__SW_VERSION__';\n"
            worker.write_text(original, encoding="utf-8")

            with self.assertRaises(ValueError):
                stamp_service_worker.finish_build(output, "not-a-commit")

            self.assertEqual(worker.read_text(encoding="utf-8"), original)

    def test_rejects_a_missing_or_already_stamped_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            worker = output / "sw.js"
            worker.write_text("const VERSION = 'old';\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                stamp_service_worker.finish_build(output, "b" * 40)


if __name__ == "__main__":
    unittest.main()

"""Advisory profiles fail clearly without affecting baseline discovery."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import flutter_test_shards as sharder


class ManifestLimitTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "test").mkdir()
        (self.root / "tool").mkdir()
        (self.root / ".flutter-version").write_text("3.47.1\n")
        for name, size in (("a", 20), ("b", 50), ("c", 90), ("d", 30), ("e", 40)):
            (self.root / f"test/{name}_test.dart").write_text("x" * size)
        self.manifest = self.root / "tool/flutter_test_timings.json"

    def test_oversized_json_integer_is_a_validation_error(self):
        name = "test/a_test.dart"
        self.manifest.write_text(json.dumps({
            "schema": "recall-flutter-test-timings/v1",
            "flutter": "3.47.1",
            "files": {name: {
                "seconds": 10 ** 400,
                "sha256": hashlib.sha256((self.root / name).read_bytes()).hexdigest(),
            }},
        }))
        with self.assertRaisesRegex(ValueError, "invalid Flutter timing manifest"):
            sharder.shards(self.root, 2)

    def test_baseline_ignores_even_a_malformed_profile(self):
        self.manifest.write_text("{")
        self.assertEqual(sharder.shards(self.root, 2, use_timings=False), [
            ["test/c_test.dart", "test/d_test.dart"],
            ["test/a_test.dart", "test/b_test.dart", "test/e_test.dart"],
        ])

    def test_sdk_mismatch_does_not_validate_obsolete_rows(self):
        self.manifest.write_text(json.dumps({
            "schema": "recall-flutter-test-timings/v1",
            "flutter": "3.46.0",
            "files": {"test/a_test.dart": {"seconds": "obsolete"}},
        }))
        files = sharder.test_files(self.root)
        self.assertEqual(sharder.file_costs(self.root, files), {
            name: (self.root / name).stat().st_size for name in files
        })


if __name__ == "__main__":
    unittest.main()

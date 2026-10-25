"""Advisory runtimes balance shards without ever selecting fewer tests."""
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import flutter_test_shards as sharder


class TimingShardTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "tool").mkdir()
        (self.root / "test").mkdir()
        (self.root / ".flutter-version").write_text("3.47.1\n")
        self.files = [f"test/{name}_test.dart" for name in "abcde"]
        for name in self.files:
            (self.root / name).write_text("x" * 10)
        self.manifest = self.root / "tool/flutter_test_timings.json"

    def write_timings(self, durations=(9, 5, 4, 3, 2)):
        data = {"schema": "recall-flutter-test-timings/v1", "flutter": "3.47.1", "files": {
            name: {"seconds": seconds, "sha256": hashlib.sha256((self.root / name).read_bytes()).hexdigest()}
            for name, seconds in zip(self.files, durations)
        }}
        self.manifest.write_text(json.dumps(data))
        return data

    def test_measured_loading_and_body_cost_override_source_size(self):
        baseline = sharder.shards(self.root, 2)
        self.write_timings()
        self.assertEqual(sharder.shards(self.root, 2), [
            [self.files[0], self.files[3]],
            [self.files[1], self.files[2], self.files[4]],
        ])
        self.assertEqual(sharder.shards(self.root, 2, use_timings=False), baseline)
        # Names deliberately disagree with runtime order: placement alone is
        # insufficient if expensive files are left until the end of a shard.
        self.write_timings((5, 2, 9, 3, 4))
        self.assertEqual(sharder.shards(self.root, 2), [
            [self.files[2], self.files[3]],
            [self.files[0], self.files[4], self.files[1]],
        ])

    def test_edited_tests_use_scaled_size_instead_of_stale_duration(self):
        self.write_timings()
        (self.root / self.files[0]).write_text("y" * 20)
        # Median of the four valid seconds/byte ratios is 0.35.
        self.assertAlmostEqual(sharder.file_costs(self.root, self.files)[self.files[0]], 7)

    def test_new_renamed_and_deleted_files_still_partition_exactly_once(self):
        self.write_timings()
        (self.root / self.files[0]).rename(self.root / "test/renamed_test.dart")
        (self.root / self.files[1]).unlink()
        (self.root / "test/new_test.dart").write_text("new synthetic test")
        current = sharder.test_files(self.root)
        for total in (1, 2, 3, 4):
            with self.subTest(total=total):
                groups = sharder.shards(self.root, total)
                self.assertTrue(all(groups))
                self.assertEqual(sorted(name for group in groups for name in group), current)
                self.assertEqual(groups, sharder.shards(self.root, total))

    def test_missing_stale_or_other_sdk_timings_fall_back_to_size(self):
        expected = sharder.file_costs(self.root, self.files)
        self.assertEqual(expected, dict.fromkeys(self.files, 10))
        self.write_timings()
        (self.root / ".flutter-version").write_text("3.48.0\n")
        self.assertEqual(sharder.file_costs(self.root, self.files), expected)
        (self.root / ".flutter-version").write_text("3.47.1\n")
        for name in self.files:
            (self.root / name).write_text("y" * 10)
        self.assertEqual(sharder.file_costs(self.root, self.files), expected)

    def test_invalid_durations_and_malformed_manifests_fail_closed(self):
        for invalid in (-1, 0, True, "5", float("nan"), float("inf")):
            with self.subTest(invalid=invalid):
                self.write_timings((invalid, 5, 4, 3, 2))
                with self.assertRaises(ValueError):
                    sharder.shards(self.root, 2)
        for invalid in ("{", "{}", '{"schema":"unknown"}',
                        '{"schema":"recall-flutter-test-timings/v1","flutter":"3.47.1","files":[]}'):
            self.manifest.write_text(invalid)
            with self.subTest(manifest=invalid), self.assertRaises(ValueError):
                sharder.shards(self.root, 2)

    def test_repository_profile_is_valid_advisory_data(self):
        data = json.loads((TOOL / "flutter_test_timings.json").read_text())
        self.assertEqual(data["schema"], "recall-flutter-test-timings/v1")
        self.assertRegex(data["flutter"], r"^\d+\.\d+\.\d+$")
        self.assertGreater(data["concurrency"], 0)
        for name, row in data["files"].items():
            with self.subTest(name=name):
                self.assertTrue(name.startswith("test/") and name.endswith("_test.dart"))
                self.assertNotIn("..", Path(name).parts)
                self.assertRegex(row["sha256"], r"^[a-f0-9]{64}$")
                self.assertTrue(math.isfinite(row["seconds"]) and row["seconds"] > 0)


if __name__ == "__main__":
    unittest.main()

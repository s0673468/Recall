"""File-level Flutter CI shards must cover every test file exactly once."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "flutter_test_shards.py"
spec = importlib.util.spec_from_file_location("flutter_test_shards", SCRIPT)
sharder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sharder)
REPO = SCRIPT.parents[1]


class ShardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, size):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x" * size)

    def test_discovers_nested_tests_and_ignores_helpers(self):
        self.write("test/a_test.dart", 1)
        self.write("test/browser/b_test.dart", 1)
        self.write("test/support/harness.dart", 1)
        self.write("test/helper.py", 1)
        self.assertEqual(sharder.test_files(self.root), ["test/a_test.dart", "test/browser/b_test.dart"])

    def test_places_largest_files_on_the_lightest_shard(self):
        for name, size in [("a", 90), ("b", 50), ("c", 40), ("d", 30), ("e", 20)]:
            self.write(f"test/{name}_test.dart", size)
        # 90 | 50+40 tie at 90, so d goes to the first shard and e to the second.
        self.assertEqual(sharder.shards(self.root, 2), [
            ["test/a_test.dart", "test/d_test.dart"],
            ["test/b_test.dart", "test/c_test.dart", "test/e_test.dart"],
        ])

    def test_refuses_an_empty_shard(self):
        self.write("test/a_test.dart", 1)
        with self.assertRaises(ValueError):
            sharder.shards(self.root, 2)

    def test_repository_shards_partition_every_test_file(self):
        everything = sharder.test_files(REPO)
        self.assertGreater(len(everything), 100)
        for total in (1, 2, 3, 4):
            with self.subTest(total=total):
                groups = sharder.shards(REPO, total)
                flat = [name for group in groups for name in group]
                self.assertEqual(sorted(flat), everything)
                self.assertTrue(all(groups))
                self.assertEqual(groups, sharder.shards(REPO, total))

    def test_cli_prints_one_shard_and_rejects_bad_index(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(sharder.main(["--total", "3", "--index", "1"]), 0)
        self.assertEqual(out.getvalue().splitlines(), sharder.shards(REPO, 3)[1])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            sharder.main(["--total", "3", "--index", "3"])


if __name__ == "__main__":
    unittest.main()

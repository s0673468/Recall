"""Behavioral checks for conservative, offline test selection."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "affected_tests.py"
spec = importlib.util.spec_from_file_location("affected_tests", SCRIPT)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write("lib/a.dart", "int a = 1;")
        self.write("lib/b.dart", "export 'a.dart';")
        self.write("lib/c.dart", "int c = 2;")
        self.write("test/a_test.dart", "import 'package:health_anki_flutter/b.dart';")
        self.write("test/c_test.dart", "import '../lib/c.dart';")
        self.write("test/contract_test.dart", "import 'dart:io';")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_transitive_exports_select_consumers_and_file_contracts(self):
        plan = selector.plan(self.root, ["lib/a.dart"])
        self.assertEqual(plan["flutter_tests"], ["test/a_test.dart", "test/contract_test.dart"])
        self.assertFalse(plan["full"])

    def test_new_uncovered_module_falls_back_to_full_flutter(self):
        self.write("lib/new.dart", "int value = 0;")
        self.assertEqual(selector.plan(self.root, ["lib/new.dart"])["flutter_tests"], ["test"])

    def test_deleted_module_still_selects_its_consumers(self):
        (self.root / "lib/a.dart").unlink()
        self.assertIn("test/a_test.dart", selector.plan(self.root, ["lib/a.dart"])["flutter_tests"])

    def test_changed_test_and_transitive_test_helper(self):
        self.write("test/helper.dart", "const int value = 1;")
        self.write("test/c_test.dart", "import 'helper.dart';")
        self.assertIn("test/c_test.dart", selector.plan(self.root, ["test/helper.dart"])["flutter_tests"])

    def test_python_tool_only_selects_its_suite(self):
        result = selector.plan(self.root, ["tools/flag_report/flag_report.py"])
        self.assertEqual(result["python_suites"], ["tools/flag_report/tests"])
        self.assertEqual(result["flutter_tests"], [])

    def test_dependency_or_unknown_change_falls_back_to_full(self):
        for name in ["pubspec.lock", "new-runtime.js", ".github/workflows/ci.yml", "tool/affected_tests.py", "config/sample.json", "tools/flag_report/requirements.txt"]:
            with self.subTest(name=name):
                self.assertTrue(selector.plan(self.root, [name])["full"])

    def test_native_changes_include_flutter_contracts_and_native_lane(self):
        result = selector.plan(self.root, ["ios/Runner/Bridge.swift"])
        self.assertEqual(result["native_lanes"], ["ios"])
        self.assertEqual(result["flutter_tests"], ["test"])

    def test_native_runner_change_requires_its_native_lane(self):
        result = selector.plan(self.root, ["tool/run_ios_tests.py"])
        self.assertIn("ios", result["native_lanes"])
        self.assertIn("tool/tests", result["python_suites"])

    def test_combined_plan_does_not_repeat_python_wrapper_suites(self):
        result = selector.plan(self.root, ["pubspec.lock"])
        commands = selector.commands(result, "portable", 2)
        for suite in ("tools/semantic_review/tests", "tools/flag_report/tests", "scripts/tests"):
            self.assertFalse(any(suite in cmd for cmd in commands))
        self.assertTrue(any("tools/recall_sync/tests" in cmd for cmd in commands))

    def test_conditional_import_selects_both_platform_consumers(self):
        self.write("lib/b.dart", "import 'c.dart' if (dart.library.io) 'a.dart';")
        self.assertIn("test/a_test.dart", selector.plan(self.root, ["lib/a.dart"])["flutter_tests"])

    def test_no_change_is_explicit_not_a_full_pass(self):
        result = selector.plan(self.root, [])
        self.assertFalse(result["full"])
        self.assertEqual(result["flutter_tests"], [])
        self.assertIn("not a merge gate", result["notice"])

    def test_docs_are_narrow_but_unknown_markdown_is_not_ignored(self):
        self.assertEqual(selector.plan(self.root, ["docs/guide.md"])["flutter_tests"], [])
        self.assertTrue(selector.plan(self.root, ["assets/runtime.md"])["full"])


class GitChangesTests(unittest.TestCase):
    def test_includes_committed_staged_unstaged_untracked_and_both_rename_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", "-C", tmp, *args], text=True).strip()
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            for name in ["old.dart", "staged.dart", "unstaged.dart"]:
                (root / name).write_text("old")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / "committed.dart").write_text("committed")
            git("add", ".")
            git("commit", "-qm", "branch")
            git("mv", "old.dart", "new.dart")
            (root / "staged.dart").write_text("staged")
            git("add", "staged.dart")
            (root / "staged.dart").write_text("old")
            (root / "unstaged.dart").write_text("dirty")
            (root / "untracked.dart").write_text("new")
            self.assertEqual(set(selector.changed_files(root, base)), {"old.dart", "new.dart", "staged.dart", "unstaged.dart", "untracked.dart", "committed.dart"})
            with self.assertRaises(subprocess.CalledProcessError):
                selector.changed_files(root, "missing-base")


if __name__ == "__main__":
    unittest.main()

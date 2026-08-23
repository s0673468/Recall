from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class BootstrapFlutterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "tool").mkdir(parents=True)
        shutil.copy2(
            REPO_ROOT / "tool" / "bootstrap_flutter",
            self.repo / "tool" / "bootstrap_flutter",
        )
        (self.repo / ".flutter-version").write_text("3.47.1\n", encoding="utf-8")
        self.cache = self.root / "cache"
        self.git_log = self.root / "git.log"

    def write_fake_git(self, sdk_version: str, *, incomplete: bool = False) -> Path:
        fake_git = self.root / f"git-{sdk_version.replace('.', '-')}"
        lines = [
            "#!/bin/sh",
            "set -eu",
            "printf '%s\\n' \"$*\" >> \"$RECALL_TEST_GIT_LOG\"",
            'target=""',
            'for argument in "$@"; do',
            '  target="$argument"',
            "done",
            'mkdir -p "$target/bin"',
        ]
        if not incomplete:
            lines.extend(
                [
                    'cat > "$target/bin/flutter" <<\'SH\'',
                    "#!/bin/sh",
                    'if [ "$1" = "--version" ] && [ "$2" = "--machine" ]; then',
                    f"  printf '%s\\n' '{{\"frameworkVersion\":\"{sdk_version}\"}}'",
                    "  exit 0",
                    "fi",
                    "exit 0",
                    "SH",
                    'chmod +x "$target/bin/flutter"',
                ]
            )
        fake_git.write_text("\n".join(lines) + "\n", encoding="utf-8")
        fake_git.chmod(fake_git.stat().st_mode | stat.S_IXUSR)
        return fake_git

    def environment(self, fake_git: Path) -> dict[str, str]:
        return os.environ | {
            "RECALL_FLUTTER_CACHE_ROOT": str(self.cache),
            "RECALL_FLUTTER_GIT_BIN": str(fake_git),
            "RECALL_FLUTTER_REPOSITORY": "https://example.invalid/flutter.git",
            "RECALL_TEST_GIT_LOG": str(self.git_log),
        }

    def run_bootstrap(self, fake_git: Path):
        return subprocess.run(
            [str(self.repo / "tool" / "bootstrap_flutter")],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment(fake_git),
        )

    def test_install_is_atomic_and_idempotent(self) -> None:
        fake_git = self.write_fake_git("3.47.1")

        first = self.run_bootstrap(fake_git)
        second = self.run_bootstrap(fake_git)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertTrue((self.cache / "flutter-3.47.1" / "bin" / "flutter").is_file())
        self.assertEqual(len(self.git_log.read_text(encoding="utf-8").splitlines()), 1)
        self.assertEqual(list(self.cache.glob(".flutter-*.stage.*")), [])

    def test_incomplete_existing_target_fails_without_clone(self) -> None:
        target = self.cache / "flutter-3.47.1"
        target.mkdir(parents=True)
        fake_git = self.write_fake_git("3.47.1")

        result = self.run_bootstrap(fake_git)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete or has the wrong version", result.stderr)
        self.assertFalse(self.git_log.exists())

    def test_wrong_download_is_not_promoted_and_stage_is_removed(self) -> None:
        fake_git = self.write_fake_git("3.44.2")

        result = self.run_bootstrap(fake_git)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 3.47.1", result.stderr)
        self.assertFalse((self.cache / "flutter-3.47.1").exists())
        self.assertEqual(list(self.cache.glob(".flutter-*.stage.*")), [])


if __name__ == "__main__":
    unittest.main()

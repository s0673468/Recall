from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
INSTALLER = REPO_ROOT / "skills" / "anki-revision" / "install.py"
SOURCE = REPO_ROOT / "skills" / "anki-revision" / "SKILL.md"


class SkillInstallTest(unittest.TestCase):
    def test_installs_and_checks_only_the_codex_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            legacy = home / ".claude" / "skills" / "anki-revision"
            legacy.mkdir(parents=True)
            legacy_file = legacy / "SKILL.md"
            legacy_file.write_text("legacy Claude copy\n", encoding="utf-8")

            environment = os.environ.copy()
            environment["HOME"] = str(home)
            environment["PYTHONDONTWRITEBYTECODE"] = "1"

            install = subprocess.run(
                [sys.executable, str(INSTALLER)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(install.returncode, 0, install.stderr)

            codex_file = home / ".codex" / "skills" / "anki-revision" / "SKILL.md"
            self.assertEqual(codex_file.read_bytes(), SOURCE.read_bytes())
            self.assertEqual(
                legacy_file.read_text(encoding="utf-8"), "legacy Claude copy\n"
            )

            check = subprocess.run(
                [sys.executable, str(INSTALLER), "--check"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            self.assertIn("installed Codex skill matches", check.stdout)
            self.assertEqual(
                legacy_file.read_text(encoding="utf-8"), "legacy Claude copy\n"
            )


if __name__ == "__main__":
    unittest.main()

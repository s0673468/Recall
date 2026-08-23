from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def write_fake_flutter(root: Path, version: str | None) -> Path:
    flutter = root / "bin" / "flutter"
    flutter.parent.mkdir(parents=True)
    metadata = "not-json" if version is None else json.dumps({"frameworkVersion": version})
    flutter.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "--version" ] && [ "$2" = "--machine" ]; then\n'
        f"  printf '%s\\n' '{metadata}'\n"
        "  exit 0\n"
        "fi\n"
        'printf \'%s\\n\' "$*" >> "$RECALL_TEST_CALL_LOG"\n',
        encoding="utf-8",
    )
    flutter.chmod(flutter.stat().st_mode | stat.S_IXUSR)
    return flutter


class FlutterWrapperTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "tool").mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "tool" / "flutterw", self.repo / "tool" / "flutterw")
        (self.repo / ".flutter-version").write_text("3.47.1\n", encoding="utf-8")
        self.call_log = self.root / "calls.log"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "RECALL_FLUTTER_CACHE_ROOT": str(self.root / "cache" / "recall"),
                "RECALL_TEST_CALL_LOG": str(self.call_log),
            }
        )
        self.environment.pop("RECALL_FLUTTER_ROOT", None)

    def run_wrapper(self, *args: str, environment: dict[str, str] | None = None):
        return subprocess.run(
            [str(self.repo / "tool" / "flutterw"), *args],
            check=False,
            capture_output=True,
            text=True,
            env=environment or self.environment,
        )

    def test_exact_environment_sdk_forwards_arguments(self) -> None:
        sdk = self.root / "sdk"
        write_fake_flutter(sdk, "3.47.1")
        environment = self.environment | {"RECALL_FLUTTER_ROOT": str(sdk)}

        result = self.run_wrapper("test", "--no-pub", environment=environment)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call_log.read_text(encoding="utf-8"), "test --no-pub\n")

    def test_wrong_environment_sdk_is_rejected(self) -> None:
        sdk = self.root / "sdk"
        write_fake_flutter(sdk, "3.44.2")
        environment = self.environment | {"RECALL_FLUTTER_ROOT": str(sdk)}

        result = self.run_wrapper("test", environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Flutter 3.47.1", result.stderr)
        self.assertFalse(self.call_log.exists())

    def test_cached_sdk_wins_over_path(self) -> None:
        cache_sdk = self.root / "cache" / "recall" / "flutter-3.47.1"
        write_fake_flutter(cache_sdk, "3.47.1")
        path_root = self.root / "path"
        write_fake_flutter(path_root, "3.44.2")
        path_bin = path_root / "bin"
        environment = self.environment | {
            "PATH": f"{path_bin}:{self.environment['PATH']}"
        }

        result = self.run_wrapper("analyze", environment=environment)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call_log.read_text(encoding="utf-8"), "analyze\n")

    def test_missing_sdk_has_bootstrap_instruction(self) -> None:
        environment = self.environment | {"PATH": "/usr/bin:/bin"}

        result = self.run_wrapper("test", environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("./tool/bootstrap_flutter", result.stderr)

    def test_malformed_sdk_metadata_is_rejected(self) -> None:
        sdk = self.root / "sdk"
        write_fake_flutter(sdk, None)
        environment = self.environment | {"RECALL_FLUTTER_ROOT": str(sdk)}

        result = self.run_wrapper("test", environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed version metadata", result.stderr)

    def test_invalid_version_file_is_rejected(self) -> None:
        (self.repo / ".flutter-version").write_text("stable\n", encoding="utf-8")

        result = self.run_wrapper("test")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid Flutter version", result.stderr)


if __name__ == "__main__":
    unittest.main()

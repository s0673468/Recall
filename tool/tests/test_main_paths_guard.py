"""Wrong-device failures must stop before Flutter can install an app."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'run_main_paths'


class MainPathsGuardTest(unittest.TestCase):
    def test_wrong_device_or_missing_ownership_never_reaches_adb(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls = root / 'calls'
            adb = root / 'adb'
            adb.write_text('#!/bin/sh\necho called > "$RECALL_GUARD_CALLS"\nexit 99\n')
            adb.chmod(0o755)
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                   'ANDROID_AVD_HOME': str(root), 'RECALL_GUARD_CALLS': str(calls)}
            for args in [('--emulator', 'physical-serial'), ('--emulator', 'emulator-5568')]:
                with self.subTest(args=args):
                    result = subprocess.run([str(SCRIPT), *args], env=env, capture_output=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse(calls.exists())

    def test_wrong_avd_never_reaches_flutter(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.recall-main-paths-owned').write_text('emulator-5568\n')
            adb = root / 'adb'
            adb.write_text('#!/bin/sh\nprintf "existing-user-avd\\nOK\\n"\n')
            adb.chmod(0o755)
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                   'ANDROID_AVD_HOME': str(root)}
            result = subprocess.run([str(SCRIPT), '--emulator', 'emulator-5568'], env=env, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b'outside the recall_prune_fixture', result.stderr)

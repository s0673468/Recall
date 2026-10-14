"""Source-only checks for the native offline benchmark's isolated build tree."""

import argparse
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tool import measure_android_cold_start as preparer


class NativePrepareTest(unittest.TestCase):
    def test_native_entry_is_copied_while_private_and_unapproved_files_are_excluded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / 'source'
            output = root / 'output'
            destination = root / 'staged'
            source.mkdir()

            def write(relative, data):
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)

            write('android/app/build.gradle.kts',
                  b'applicationId = "com.german.health_anki_flutter"\n')
            write('pubspec.yaml', b'flutter:\n  assets:\n    - assets/private/\n')
            write('tool/fixtures/synthetic_android_main.dart', b'void main() {}\n')
            write('tool/fixtures/synthetic_recall_flow.dart', b'// invented flow\n')
            write('tool/fixtures/synthetic_native_offline_restart_main.dart',
                  b'void main() {} // invented offline restart\n')
            write('tool/run_synthetic_native_offline_restart.py',
                  b'# runner-only technical script\n')
            write('tool/native_offline_receipt_contract.py',
                  b'# runner-only receipt contract\n')
            write('assets/fonts/Invented-Regular.ttf', b'invented-font')
            write('assets/cards/excluded.json', b'invented-exclusion-sentinel')
            write('tool/fixtures/.env', b'credential-sentinel')
            write('android/key.properties', b'credential-sentinel')
            write('lib/fixture.dart', b'// technical source\n')

            with (patch.object(preparer, 'require_ci'), patch.object(
                preparer, 'isolated_gradle',
                side_effect=lambda data: data.replace(
                    b'com.german.health_anki_flutter',
                    b'com.german.recall.syntheticbenchmark')),
                 patch.object(preparer, 'technical_assets_only',
                              return_value=b'flutter:\n  assets:\n    - assets/fonts/\n'), patch.dict(
                os.environ, {'RUNNER_TEMP': str(root)}, clear=False
            )):
                receipt = preparer.prepare(argparse.Namespace(
                    source=source, destination=destination,
                    source_commit='a' * 40, output=output / 'provenance.json'))

            self.assertEqual(receipt['package'],
                             'com.german.recall.syntheticbenchmark')
            self.assertTrue((destination / 'tool/fixtures/synthetic_native_offline_restart_main.dart').is_file())
            self.assertNotIn(b'com.german.health_anki_flutter',
                             (destination / 'android/app/build.gradle.kts').read_bytes())
            self.assertIn(b'com.german.recall.syntheticbenchmark',
                          (destination / 'android/app/build.gradle.kts').read_bytes())
            self.assertFalse((destination / 'assets/cards').exists())
            self.assertFalse((destination / 'tool/fixtures/.env').exists())
            self.assertFalse((destination / 'tool/run_synthetic_native_offline_restart.py').exists())
            self.assertFalse((destination / 'tool/native_offline_receipt_contract.py').exists())
            self.assertFalse((destination / 'android/key.properties').exists())
            self.assertTrue((destination / 'assets/fonts/Invented-Regular.ttf').is_file())

    def test_allowed_extension_does_not_make_symlink_safe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'target.dart'
            target.write_text('// invented\n')
            link = root / 'fixture.dart'
            link.symlink_to(target)
            with self.assertRaises(preparer.Refused) as caught:
                preparer.regular_bytes(link)
            self.assertEqual(caught.exception.code, 'nonregular_input')


if __name__ == '__main__':
    unittest.main()

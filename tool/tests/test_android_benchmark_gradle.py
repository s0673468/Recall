"""Technical Gradle source isolation; no SDK, credentials or app data needed."""

from pathlib import Path
import sys
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import measure_android_cold_start as cold


class AndroidBenchmarkGradleTests(unittest.TestCase):
    def test_current_source_rewrites_only_one_application_id(self):
        data = (TOOL.parent / 'android/app/build.gradle.kts').read_bytes()
        original = b'        applicationId = "com.german.health_anki_flutter"\n'
        isolated = b'        applicationId = "com.german.recall.syntheticbenchmark"\n'
        self.assertEqual(data.count(original), 1)
        result = cold.isolated_gradle(data)
        self.assertEqual(result, data.replace(original, isolated, 1))
        self.assertEqual(result.count(isolated), 1)
        self.assertNotIn(original, result)

    def test_superseded_reminder_source_pin_is_refused(self):
        data = (TOOL.parent / 'android/app/build.gradle.kts').read_bytes()
        added = b'    testImplementation("org.robolectric:robolectric:4.16.1")\n'
        self.assertEqual(data.count(added), 1)
        previous = data.replace(added, b'', 1)
        self.assertEqual(cold.sha(previous),
                         '729f278b435614cb6c6060000a3cec7ab9ca1de31d42098a5b693921951beb5d')
        with self.assertRaises(cold.Refused) as caught:
            cold.isolated_gradle(previous)
        self.assertEqual(caught.exception.code, 'gradle_source_pin_changed')

    def test_unapproved_source_change_is_refused(self):
        data = (TOOL.parent / 'android/app/build.gradle.kts').read_bytes()
        with self.assertRaises(cold.Refused) as caught:
            cold.isolated_gradle(data + b'// synthetic unapproved change\n')
        self.assertEqual(caught.exception.code, 'gradle_source_pin_changed')

    def test_synthetic_source_rewrites_only_application_id(self):
        data = (b'android {\n  namespace = "com.german.health_anki_flutter"\n'
                b'  defaultConfig {\n'
                b'    applicationId = "com.german.health_anki_flutter"\n'
                b'  }\n}\n')
        with patch.object(cold, 'BASE_GRADLE_SHA', cold.sha(data)):
            result = cold.isolated_gradle(data)
        self.assertEqual(result, data.replace(
            b'applicationId = "com.german.health_anki_flutter"',
            b'applicationId = "com.german.recall.syntheticbenchmark"', 1))
        self.assertEqual(result.count(b'com.german.recall.syntheticbenchmark'), 1)

    def test_synthetic_missing_or_duplicate_application_id_is_refused(self):
        line = b'  applicationId = "com.german.health_anki_flutter"\n'
        for data in (b'android {}\n', line * 2):
            with self.subTest(data=data), patch.object(
                    cold, 'BASE_GRADLE_SHA', cold.sha(data)):
                with self.assertRaises(cold.Refused) as caught:
                    cold.isolated_gradle(data)
                self.assertEqual(caught.exception.code, 'application_id_transform_refused')


if __name__ == '__main__':
    unittest.main()

"""Closed synthetic event regressions. No ADB, APK, SDK or emulator is invoked."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'measure_android_cold_start.py'
spec = importlib.util.spec_from_file_location('cold_start_consumer', SCRIPT)
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)
COMMIT = 'a' * 40
PID = 55


def failure(**changes):
    return {'schema': consumer.SCHEMA, 'phase': 'failed', 'source_commit': COMMIT,
            'build_mode': 'debug', 'environment': 'isolated-android-emulator',
            'pid': PID, 'failure_code': 'synthetic_phase_failed',
            'failed_phase': 'deck_load', **changes}


class TechnicalAssetManifestTests(unittest.TestCase):
    def test_current_manifest_retains_runtime_preferences_dependency_and_fonts_only(self):
        manifest = (SCRIPT.parent.parent / 'pubspec.yaml').read_bytes()
        transformed = consumer.technical_assets_only(manifest)
        dependencies = transformed.split(b'dev_dependencies:', 1)[0]
        self.assertIn(b'  shared_preferences_platform_interface: ^2.4.2\n', dependencies)
        self.assertEqual(transformed.split(b'  assets:\n', 1)[1],
                         b'    - assets/fonts/\n')
        self.assertEqual(transformed.split(b'  assets:\n', 1)[0],
                         manifest.split(b'  assets:\n', 1)[0])

    def test_unapproved_manifest_and_asset_additions_are_refused(self):
        manifest = (SCRIPT.parent.parent / 'pubspec.yaml').read_bytes()
        changed_assets = manifest.replace(b'    - assets/fonts/\n',
            b'    - assets/fonts/\n    - assets/invented-study.json\n')
        self.assertNotEqual(changed_assets, manifest)
        for unapproved in (manifest + b'# unreviewed manifest change\n', changed_assets):
            with self.subTest(asset_change=unapproved == changed_assets):
                with self.assertRaises(consumer.Refused) as caught:
                    consumer.technical_assets_only(unapproved)
                self.assertEqual(caught.exception.code, 'pubspec_source_pin_changed')


    def test_version_only_bump_keeps_pin_but_extra_version_line_is_refused(self):
        manifest = (SCRIPT.parent.parent / 'pubspec.yaml').read_bytes()
        bumped = re.sub(rb'(?m)^version:[^\n]*$', b'version: 99.0.0+99999', manifest)
        self.assertNotEqual(bumped, manifest)
        self.assertIn(b'version: 99.0.0+99999\n', consumer.technical_assets_only(bumped))
        with self.assertRaises(consumer.Refused) as caught:
            consumer.technical_assets_only(bumped + b'version: 1.0.0+1\n')
        self.assertEqual(caught.exception.code, 'pubspec_source_pin_changed')

class ClosedFailureTests(unittest.TestCase):
    def test_allowlisted_phases_survive_projection(self):
        for phase in consumer.FIXTURE_FAILED_PHASES:
            with self.subTest(phase=phase):
                error = consumer.closed_fixture_failure(failure(failed_phase=phase), PID, COMMIT)
                self.assertEqual(error.code, 'fixture_reported_failure')
                self.assertEqual(error.failure_code, 'synthetic_phase_failed')
                self.assertEqual(error.failed_phase, phase)

    def test_build_guard_without_source_define_survives(self):
        value = failure(failure_code='fixture_build_required', source_commit='')
        del value['failed_phase']
        error = consumer.closed_fixture_failure(value, PID, COMMIT)
        self.assertEqual(error.failure_code, 'fixture_build_required')
        self.assertIsNone(error.failed_phase)

    def test_unknown_labels_and_fields_are_refused_without_reflection(self):
        for value in [failure(failure_code='untrusted-code'), failure(failed_phase='private-text'),
                      failure(raw_exception='private-text'), failure(failed_phase=[]),
                      failure(failure_code={'payload':'private-text'}),
                      {key:value for key,value in failure().items() if key != 'failed_phase'}]:
            with self.subTest(keys=sorted(value)):
                with self.assertRaises(consumer.Refused) as caught:
                    consumer.closed_fixture_failure(value, PID, COMMIT)
                self.assertEqual(caught.exception.code, 'fixture_failure_schema_invalid')
                self.assertIsNone(caught.exception.failure_code)
                self.assertIsNone(caught.exception.failed_phase)

    def test_foreign_event_identity_is_refused(self):
        for change in [{'pid':56}, {'pid':True}, {'source_commit':'b'*40},
                       {'build_mode':'profile'}, {'environment':'personal-device'}]:
            with self.subTest(change=change):
                with self.assertRaises(consumer.Refused) as caught:
                    consumer.closed_fixture_failure(failure(**change), PID, COMMIT)
                self.assertEqual(caught.exception.code, 'fixture_failure_identity_invalid')
                self.assertIsNone(caught.exception.failure_code)

    def test_actual_run_branch_projects_failure_and_stops_only_fixture_package(self):
        calls = []
        launched = False
        event = '123.456 55 55 I flutter: '+consumer.SENTINEL+json.dumps(failure())

        def fake_adb(serial, *arguments, **kwargs):
            nonlocal launched
            calls.append(arguments)
            if arguments[:2] == ('shell','getprop'):
                return '1' if arguments[-1]=='ro.kernel.qemu' else 'x86_64'
            if arguments[:3] == ('shell','am','start'):
                launched=True
                return 'Status: ok\nTotalTime: 200\nWaitTime: 211\n'
            if arguments[:2] == ('shell','pidof'):
                return str(PID) if launched else ''
            if arguments[:3] == ('shell','pm','clear'):
                return 'Success'
            if arguments[0] == 'logcat':
                return event
            return 'Success'

        with tempfile.TemporaryDirectory() as directory:
            apk=Path(directory)/'synthetic.apk';apk.write_bytes(b'synthetic-test-placeholder')
            args=type('Args',(),{'samples':3,'sample_timeout':15,'source_commit':COMMIT,'apk':apk})()
            with patch.object(consumer,'require_ci'), patch.object(Path,'exists',return_value=True), \
                 patch.object(consumer.os,'access',return_value=True), \
                 patch.object(consumer,'apk_identity',return_value=(consumer.PACKAGE,'fixture.MainActivity')), \
                 patch.object(consumer,'adb',side_effect=fake_adb), \
                 patch.object(consumer.subprocess,'run',return_value=subprocess.CompletedProcess(
                     ['adb','devices'],0,'List of devices attached\nemulator-5554\tdevice\n','')) as process:
                with self.assertRaises(consumer.Refused) as caught:
                    consumer.run(args)
            self.assertEqual(caught.exception.failed_phase,'deck_load')
            self.assertEqual(caught.exception.failure_code,'synthetic_phase_failed')
            self.assertEqual(process.call_count,1)
            self.assertEqual(calls[-1],('shell','am','force-stop',consumer.PACKAGE))

    def test_main_writes_only_closed_failure_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'failure.json'
            argv=['measure','run','--apk','synthetic.apk','--source-commit',COMMIT,'--output',str(output)]
            expected=consumer.closed_fixture_failure(failure(),PID,COMMIT)
            with patch.object(consumer.sys,'argv',argv), patch.object(consumer,'run',side_effect=expected), \
                 contextlib.redirect_stdout(io.StringIO()) as console:
                status=consumer.main()
            result=json.loads(output.read_text())
            self.assertEqual(status,1)
            self.assertEqual(result['closed_failure_code'],'fixture_reported_failure')
            self.assertEqual(result['failure_code'],'synthetic_phase_failed')
            self.assertEqual(result['failed_phase'],'deck_load')
            self.assertEqual(result,json.loads(console.getvalue()))
            self.assertEqual(set(result),{'schema','closed_failure_code','raw_logs_printed',
                'normal_app_or_personal_data_changed','failure_code','failed_phase'})
            self.assertFalse(result['raw_logs_printed'])

    def test_constructor_never_carries_unknown_payload_labels(self):
        error=consumer.Refused('fixture_failure_schema_invalid',failure_code='private-text',failed_phase='private-text')
        self.assertIsNone(error.failure_code)
        self.assertIsNone(error.failed_phase)


if __name__ == '__main__':
    unittest.main()

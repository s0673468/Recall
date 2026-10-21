"""Benchmark source pins must match the current tree.

The synthetic benchmark workflows are path-filtered and optional, so a PR that
changes a pinned app file does not run them. These checks run in the required
tool tests instead: a change to a pinned file fails here, in its own PR, with
the pin to refresh. Re-pin by regenerating the pinned value; for the review
controller also regenerate tool/fixtures/checkpoint-drain-only.patch against
the new controller (see tool/fixtures/README-native-checkpoint-cost.md).
"""
import hashlib
from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
ROOT = TOOL.parent
sys.path.insert(0, str(TOOL))
import measure_android_cold_start as cold
import native_checkpoint_contract as contract
import prepare_native_checkpoint_cost as prepare


def source(relative: str) -> bytes:
    return (ROOT / relative).read_bytes()


class BenchmarkSourcePinTests(unittest.TestCase):
    def assertPinned(self, pin_name: str, relative: str, actual: str, expected: str) -> None:
        self.assertEqual(actual, expected,
                         f'{relative} changed; re-pin {pin_name} (and its benchmark inputs)')

    def test_cold_start_build_inputs(self):
        self.assertPinned('measure_android_cold_start.BASE_GRADLE_SHA', 'android/app/build.gradle.kts',
                          cold.sha(source('android/app/build.gradle.kts')), cold.BASE_GRADLE_SHA)
        self.assertPinned('measure_android_cold_start.BASE_PUBSPEC_SHA', 'pubspec.yaml',
                          cold.pubspec_pin_sha(source('pubspec.yaml')), cold.BASE_PUBSPEC_SHA)

    def test_native_cost_controller_store_fixture_and_patch(self):
        controller = source(prepare.CONTROLLER)
        store = source(prepare.STORE)
        self.assertPinned('native_checkpoint_contract.BASE_CONTROLLER', prepare.CONTROLLER,
                          cold.sha(controller), contract.BASE_CONTROLLER)
        self.assertPinned('native_checkpoint_contract.STORE_SHA', prepare.STORE,
                          cold.sha(store), contract.STORE_SHA)
        blob = hashlib.sha1(b'blob %d\0' % len(store) + store).hexdigest()
        self.assertPinned('native_checkpoint_contract.STORE_BLOB', prepare.STORE,
                          blob, contract.STORE_BLOB)
        self.assertPinned('native_checkpoint_contract.FIXTURE_SHA', prepare.ENTRY,
                          cold.sha(source(prepare.ENTRY)), contract.FIXTURE_SHA)
        patch_bytes = source('tool/fixtures/checkpoint-drain-only.patch')
        self.assertPinned('native_checkpoint_contract.PATCH_SHA',
                          'tool/fixtures/checkpoint-drain-only.patch',
                          cold.sha(patch_bytes), contract.PATCH_SHA)
        # Raises Refused unless the patch applies cleanly and yields CHECKPOINT_CONTROLLER.
        prepare.apply_checkpoint(controller, patch_bytes)


if __name__ == '__main__':
    unittest.main()

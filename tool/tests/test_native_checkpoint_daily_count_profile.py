"""Bind daily-count benchmark inputs and refuse the superseded byte profile."""

import hashlib
from pathlib import Path
import re
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
ROOT = TOOL.parent
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
import prepare_native_checkpoint_cost as prepare
from test_native_checkpoint_cost import receipt, source_proof


PREVIOUS_SOURCE = 'ec18dcf195182ccecaa16ed767e5c6a60daf3c1a'
PREVIOUS_BASE = '22e0f2ca4335c5275616757f2ecfdb5ef30113cbd858ef5253f1ecaa903db515'
PREVIOUS_CHECKPOINT = '8bf811b993b18041a1b412c9b4bddcd2d0feeb3227a68c051b3b2acf44a6b490'
PREVIOUS_PATCH = 'e2b1fd925a43d0f17325aaa5f0afb9e7880a0903320d21f819e55fd14653ddd7'
PREVIOUS_FIXTURE = 'f755bef90522e187f3449481b9f59e23eacfd3a0bf407ad8ad2fd410e9f15b1b'
PREVIOUS_STORE = '062d437ee3a6f3e8b378ef1c8cfaac1e4e13720bf2d33cfa3b876bac79332d97'
PREVIOUS_STORE_BLOB = '4263f81a878b1543ba39fb5339536d688c3e54a8'


class DailyCountProfileTests(unittest.TestCase):
    def test_superseded_receipt_and_provenance_pins_are_individually_refused(self):
        for variant in ('baseline', 'checkpoint'):
            stale_pins = {
                'baseline_source_commit': PREVIOUS_SOURCE,
                'controller_sha256': (
                    PREVIOUS_BASE if variant == 'baseline' else PREVIOUS_CHECKPOINT
                ),
                'fixture_sha256': PREVIOUS_FIXTURE,
                'store_git_blob': PREVIOUS_STORE_BLOB,
            }
            if variant == 'checkpoint':
                stale_pins['patch_sha256'] = PREVIOUS_PATCH
            for key, stale in stale_pins.items():
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused):
                        contract.validate_provenance(
                            {**source_proof(variant), key: stale}, variant,
                        )
                    for count in (128, 512):
                        with self.assertRaises(contract.Refused):
                            contract.validate(
                                {**receipt(variant, count), key: stale},
                                variant=variant, count=count, pid=101,
                                fixture_sha=contract.FIXTURE_SHA,
                            )

            for key, stale in (
                ('store_sha256', PREVIOUS_STORE),
                ('baseline_controller_sha256', PREVIOUS_BASE),
            ):
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused):
                        contract.validate_provenance(
                            {**source_proof(variant), key: stale}, variant,
                        )

    def test_workflow_and_entrypoint_use_the_same_source_guards(self):
        workflow = (ROOT / '.github/workflows/recall-synthetic-native-cost.yml').read_text()
        entry = (ROOT / prepare.ENTRY).read_text()
        for define, expected in (
            ('RECALL_BASE_COMMIT', [contract.SOURCE, contract.SOURCE]),
            ('RECALL_CONTROLLER_SHA256', [contract.BASE_CONTROLLER, contract.CHECKPOINT_CONTROLLER]),
            ('RECALL_PATCH_SHA256', ['none', contract.PATCH_SHA]),
            ('RECALL_FIXTURE_SHA256', [contract.FIXTURE_SHA, contract.FIXTURE_SHA]),
        ):
            with self.subTest(define=define):
                self.assertEqual(re.findall(r'--dart-define=' + define + r'=(\w+)', workflow), expected)
        for name, expected in (
            ('_baselineControllerSha', contract.BASE_CONTROLLER),
            ('_checkpointControllerSha', contract.CHECKPOINT_CONTROLLER),
            ('_checkpointPatchSha', contract.PATCH_SHA),
            ('_storeBlob', contract.STORE_BLOB),
        ):
            with self.subTest(guard=name):
                match = re.search(r'const ' + name + r"\s*=\s*'([^']+)'", entry)
                self.assertIsNotNone(match)
                self.assertEqual(match[1], expected)
        self.assertIn("_require(_baseCommit == '" + contract.SOURCE + "');", entry)
        self.assertEqual(hashlib.sha256(entry.encode()).hexdigest(), contract.FIXTURE_SHA)


if __name__ == '__main__':
    unittest.main()

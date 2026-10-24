"""The like feature re-pin must continue refusing the previous byte profile."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_checkpoint_contract as contract
from test_native_checkpoint_cost import source_proof


class LikeSourceProfileTests(unittest.TestCase):
    def test_previous_controller_store_and_fixture_profiles_are_refused(self):
        previous = {
            'baseline_controller_sha256': '22e0f2ca4335c5275616757f2ecfdb5ef30113cbd858ef5253f1ecaa903db515',
            'store_sha256': '062d437ee3a6f3e8b378ef1c8cfaac1e4e13720bf2d33cfa3b876bac79332d97',
            'store_git_blob': '4263f81a878b1543ba39fb5339536d688c3e54a8',
            'fixture_sha256': 'f755bef90522e187f3449481b9f59e23eacfd3a0bf407ad8ad2fd410e9f15b1b',
        }
        for variant in ('baseline', 'checkpoint'):
            proof = source_proof(variant)
            contract.validate_provenance(proof, variant)
            for key, value in previous.items():
                with self.subTest(variant=variant, field=key):
                    with self.assertRaises(contract.Refused) as caught:
                        contract.validate_provenance({**proof, key: value}, variant)
                    self.assertEqual(caught.exception.code, 'source_provenance_binding_invalid')

"""The offline-sync refresh refuses the superseded benchmark profile."""

from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


PREVIOUS_SOURCE = 'd360f6189b80c36218b73b6747fd29c1b906ed0e'
PREVIOUS_BASE_CONTROLLER = '96fd789c51674ae8d1a46239fd8fd8b44124003d1bc283ca60b723aca6f1fb1d'
PREVIOUS_CHECKPOINT_CONTROLLER = 'a22f93da407b879d09e38006f76b4150baca7941f2c4975c12bb147ace7671cd'
PREVIOUS_PATCH_SHA = '532c66c100e7a8c5cf695ae5ae4d2ca571c9013f1a07e63b774eef04256e25c0'
PREVIOUS_FIXTURE_SHA = '5e696ed0599c424116a2f5ec1bda29acf750e0d4debe8acf9bffc5232bcee829'


class OfflineSyncProfileTests(unittest.TestCase):
    def test_superseded_receipt_and_provenance_pins_are_individually_refused(self):
        for variant, controller in (
            ('baseline', PREVIOUS_BASE_CONTROLLER),
            ('checkpoint', PREVIOUS_CHECKPOINT_CONTROLLER),
        ):
            stale = {
                'baseline_source_commit': PREVIOUS_SOURCE,
                'controller_sha256': controller,
                'fixture_sha256': PREVIOUS_FIXTURE_SHA,
            }
            if variant == 'checkpoint':
                stale['patch_sha256'] = PREVIOUS_PATCH_SHA
            current_proof = source_proof(variant)
            contract.validate_provenance(current_proof, variant)
            for count in (128, 512):
                current = receipt(variant, count)
                contract.validate(
                    current, variant=variant, count=count, pid=101,
                    fixture_sha=contract.FIXTURE_SHA,
                )
                for key, value in stale.items():
                    with self.subTest(variant=variant, count=count, pin=key):
                        with self.assertRaises(contract.Refused) as caught:
                            contract.validate(
                                {**current, key: value}, variant=variant,
                                count=count, pid=101, fixture_sha=contract.FIXTURE_SHA,
                            )
                        self.assertEqual(caught.exception.code,
                                         'fixture_identity_invalid' if key == 'baseline_source_commit'
                                         else 'fixture_source_binding_invalid')
            for key, value in {**stale, 'baseline_controller_sha256': PREVIOUS_BASE_CONTROLLER}.items():
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused) as caught:
                        contract.validate_provenance({**current_proof, key: value}, variant)
                    self.assertEqual(caught.exception.code,
                                     'source_provenance_invalid' if key == 'baseline_source_commit'
                                     else 'source_provenance_binding_invalid')

    def test_superseded_fixture_argument_cannot_qualify_receipts(self):
        for variant in ('baseline', 'checkpoint'):
            for count in (128, 512):
                for fixture in (PREVIOUS_FIXTURE_SHA, contract.FIXTURE_SHA):
                    with self.subTest(variant=variant, count=count, fixture=fixture):
                        with self.assertRaises(contract.Refused) as caught:
                            contract.validate(
                                {**receipt(variant, count), 'fixture_sha256': fixture},
                                variant=variant, count=count, pid=101,
                                fixture_sha=PREVIOUS_FIXTURE_SHA,
                            )
                        self.assertEqual(caught.exception.code, 'fixture_source_binding_invalid')


if __name__ == '__main__':
    unittest.main()

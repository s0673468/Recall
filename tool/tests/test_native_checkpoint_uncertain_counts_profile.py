"""Refuse Store and fixture bindings superseded by uncertain-ACK reconciliation."""

from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


PREVIOUS_STORE_SHA = 'ce0e19e5abda6a2270fd016be3619e81db219bae5180cc0c632aed92a71fc95e'
REVIEWED_STORE_SHA = 'a8e964f5ab65a66b7a7e0fdab7cbac8946d9309bed7c298995f4c7ad5ce225fd'
PREVIOUS_STORE_BLOB = 'f7c51c9672270293016cc2d20fcf1bf33ee1832b'
PREVIOUS_FIXTURE_SHA = '04ac9781747023ac0922bfb8fc91e830b5d5a406a30bea5f32258df1d5dc72b4'


class UncertainCountsProfileTests(unittest.TestCase):
    def test_superseded_receipt_bindings_are_individually_refused(self):
        for variant in ('baseline', 'checkpoint'):
            for count in (128, 512):
                current = receipt(variant, count)
                contract.validate(
                    current, variant=variant, count=count, pid=101,
                    fixture_sha=contract.FIXTURE_SHA,
                )
                for key, stale in (
                    ('store_git_blob', PREVIOUS_STORE_BLOB),
                    ('fixture_sha256', PREVIOUS_FIXTURE_SHA),
                ):
                    with self.subTest(variant=variant, count=count, pin=key):
                        with self.assertRaises(contract.Refused) as caught:
                            contract.validate(
                                {**current, key: stale}, variant=variant,
                                count=count, pid=101, fixture_sha=contract.FIXTURE_SHA,
                            )
                        self.assertEqual(caught.exception.code, 'fixture_source_binding_invalid')

    def test_superseded_provenance_bindings_are_individually_refused(self):
        for variant in ('baseline', 'checkpoint'):
            current = source_proof(variant)
            contract.validate_provenance(current, variant)
            for key, stale in (
                ('store_sha256', PREVIOUS_STORE_SHA),
                ('store_sha256', REVIEWED_STORE_SHA),
                ('store_git_blob', PREVIOUS_STORE_BLOB),
                ('fixture_sha256', PREVIOUS_FIXTURE_SHA),
            ):
                with self.subTest(variant=variant, pin=key, stale=stale):
                    with self.assertRaises(contract.Refused) as caught:
                        contract.validate_provenance({**current, key: stale}, variant)
                    self.assertEqual(caught.exception.code, 'source_provenance_binding_invalid')

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

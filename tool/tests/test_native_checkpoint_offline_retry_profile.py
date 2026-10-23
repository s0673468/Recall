"""The offline-retry re-pin refuses the superseded Store and source profile."""

from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


PREVIOUS_SOURCE = '44f71d0247e6722a377afe2a557906b718d8b7ef'
PREVIOUS_STORE_SHA = '3b00f9b6a971558b27f8f7ada7f6e83d19be5522a6a11b5f75c84ab05f7990b1'
PREVIOUS_STORE_BLOB = '222866a8df750e080e6ed04bc382920076a4b2ee'
PREVIOUS_FIXTURE_SHA = '7762e90ac1daba4705672430179a391ab54e10fca3c4d829e7e8b6e93a4e177c'


class OfflineRetryProfileTests(unittest.TestCase):
    def test_superseded_receipt_pins_are_individually_refused(self):
        for variant in ('baseline', 'checkpoint'):
            for count in (128, 512):
                current = receipt(variant, count)
                contract.validate(
                    current, variant=variant, count=count, pid=101,
                    fixture_sha=contract.FIXTURE_SHA,
                )
                for key, value, code in (
                    ('baseline_source_commit', PREVIOUS_SOURCE, 'fixture_identity_invalid'),
                    ('store_git_blob', PREVIOUS_STORE_BLOB, 'fixture_source_binding_invalid'),
                    ('fixture_sha256', PREVIOUS_FIXTURE_SHA, 'fixture_source_binding_invalid'),
                ):
                    with self.subTest(variant=variant, count=count, pin=key):
                        with self.assertRaises(contract.Refused) as caught:
                            contract.validate(
                                {**current, key: value}, variant=variant,
                                count=count, pid=101, fixture_sha=contract.FIXTURE_SHA,
                            )
                        self.assertEqual(caught.exception.code, code)

    def test_superseded_provenance_pins_are_individually_refused(self):
        for variant in ('baseline', 'checkpoint'):
            current = source_proof(variant)
            contract.validate_provenance(current, variant)
            for key, value, code in (
                ('baseline_source_commit', PREVIOUS_SOURCE, 'source_provenance_invalid'),
                ('store_sha256', PREVIOUS_STORE_SHA, 'source_provenance_binding_invalid'),
                ('store_git_blob', PREVIOUS_STORE_BLOB, 'source_provenance_binding_invalid'),
                ('fixture_sha256', PREVIOUS_FIXTURE_SHA, 'source_provenance_binding_invalid'),
            ):
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused) as caught:
                        contract.validate_provenance({**current, key: value}, variant)
                    self.assertEqual(caught.exception.code, code)

    def test_superseded_fixture_argument_cannot_qualify_old_or_current_receipts(self):
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

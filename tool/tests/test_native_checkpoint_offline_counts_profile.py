"""Offline deck counts re-pin the Store and refuse the superseded profile."""

import hashlib
from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
ROOT = TOOL.parent
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
import prepare_native_checkpoint_cost as prepare
from test_native_checkpoint_cost import receipt, source_proof


PREVIOUS_SOURCE = '295d397af7210fc2bc7b5af8eb0302729c82317f'
PREVIOUS_STORE_SHA = 'cb1466223ae37b871cd4f705a9ebd5dddc4e06390cd4313d3ebfed2b3243b7e8'
PREVIOUS_STORE_BLOB = '434b4f83aac7383fb1330504e1446956354c0a6e'
PREVIOUS_FIXTURE_SHA = '2a5545b26617eaef029de147f0f808be23d832b9696ca7f461f22862a0a8f226'


class OfflineCountsProfileTests(unittest.TestCase):
    def test_source_bytes_match_the_profile_and_checkpoint_patch(self):
        controller = (ROOT / prepare.CONTROLLER).read_bytes()
        store = (ROOT / prepare.STORE).read_bytes()
        payload = (TOOL / 'fixtures/checkpoint-drain-only.patch').read_bytes()
        self.assertEqual(hashlib.sha256(controller).hexdigest(), contract.BASE_CONTROLLER)
        self.assertEqual(hashlib.sha256(store).hexdigest(), contract.STORE_SHA)
        blob = b'blob ' + str(len(store)).encode() + b'\0' + store
        self.assertEqual(hashlib.sha1(blob).hexdigest(), contract.STORE_BLOB)
        checkpoint = prepare.apply_checkpoint(controller, payload)
        self.assertEqual(hashlib.sha256(checkpoint).hexdigest(), contract.CHECKPOINT_CONTROLLER)

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

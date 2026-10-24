"""The merged experiment binds both daily receipts and like recovery source."""

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


class MergedProfileTests(unittest.TestCase):
    def test_checkpoint_applies_to_the_combined_production_source(self):
        controller = (ROOT / prepare.CONTROLLER).read_bytes()
        store = (ROOT / prepare.STORE).read_bytes()
        self.assertEqual(hashlib.sha256(store).hexdigest(), contract.STORE_SHA)
        blob = hashlib.sha1(b'blob ' + str(len(store)).encode() + b'\0' + store)
        self.assertEqual(blob.hexdigest(), contract.STORE_BLOB)
        checkpoint = prepare.apply_checkpoint(
            controller, (TOOL / 'fixtures/checkpoint-drain-only.patch').read_bytes(),
        ).decode()
        # Both the intermediate checkpoint and final drain must retain the
        # receipt before discarding the only durable pending review.
        flush = checkpoint.split('Future<bool> _flushOnce() async {', 1)[1]
        flush = flush.split('Future<Set<Object>> _markRemainingAttempted(', 1)[0]
        self.assertEqual(flush.count('await store.dailyReviewEvents('), 2)
        self.assertEqual(flush.count('await store.removeAcknowledgedReviews('), 2)
        for removal in flush.split('await store.removeAcknowledgedReviews(')[:-1]:
            self.assertIn('requirePersistence: true', removal)
            self.assertIn('includePending: false', removal)
        self.assertIn('Future<void> _loadLikedFlags()', checkpoint)
        self.assertIn('Future<void> _refreshLikedFlags()', checkpoint)

    def test_pre_merge_daily_and_likes_profiles_are_refused(self):
        profiles = (
            ('3e64b782e2b86e422bd15fcc9e767390dd2df081',
             'fbc440a788599df24d193a252764bd0ffc33753f687a7e32d2e8672f5ee64ec7',
             'f89393d4ffc2751792fb19e07884532c22dbdb963b6a3c29e33e045cf415583e',
             '5e664ef65dc5633e0ebd402bf2b82d60f9e525775d139423ce7510eced84d6da',
             '2d70d9c6aa4d228c87456fce6649884b2f4a09fe',
             'c6fa9bc8ca5dad9c192adf07a9e47a104607aab132974bf3ce8602ee5469cf63',
             '012e6add7ce830b89ca707e5140003072aaf52c8e4c0921044750aaf511d31c5'),
            ('bae90089cb6b9fe3f2eb66513d84a9bb11ad0c5a',
             'c8fc79c32fe0551ab615fcf01577d454fba2b2483b8d5543a9e56ab2c678cb63',
             '5f18a20d911a401b579dc682903bc1be5c2e53c61fd1ace4b0b440774348c6f6',
             '7d17894d65adde9fff97b338c6fafeb1b2133c826b3fea61f43954fa0d1ef929',
             'd83efa92a8cbbbf2135803c25ccaba52fc1d696e',
             '477cd41c821ca72765ee37a9aced795f07bfc69c3b57179f5be3de1e6f814a3a',
             '81e0c27acf476d932a00b6c48151b9ecf1234a7800142955baa4d55cb1ba3662'),
        )
        for source, baseline, checkpoint, store, blob, patch, fixture in profiles:
            for variant in ('baseline', 'checkpoint'):
                stale = dict(
                    baseline_source_commit=source,
                    controller_sha256=baseline if variant == 'baseline' else checkpoint,
                    store_git_blob=blob,
                    fixture_sha256=fixture,
                )
                if variant == 'checkpoint':
                    stale['patch_sha256'] = patch
                for key, value in stale.items():
                    with self.subTest(source=source, variant=variant, pin=key):
                        for count in (128, 512):
                            with self.assertRaises(contract.Refused):
                                contract.validate(
                                    {**receipt(variant, count), key: value},
                                    variant=variant, count=count, pid=101,
                                    fixture_sha=contract.FIXTURE_SHA,
                                )
                        with self.assertRaises(contract.Refused):
                            contract.validate_provenance(
                                {**source_proof(variant), key: value}, variant,
                            )
                for key, value in dict(
                    baseline_controller_sha256=baseline, store_sha256=store,
                ).items():
                    with self.subTest(source=source, variant=variant, pin=key):
                        with self.assertRaises(contract.Refused):
                            contract.validate_provenance(
                                {**source_proof(variant), key: value}, variant,
                            )

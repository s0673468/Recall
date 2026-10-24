"""The reviewed likes profile refuses receipts from before the recovery fix."""

from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


PREVIOUS_SOURCE = 'ec18dcf195182ccecaa16ed767e5c6a60daf3c1a'
PREVIOUS_BASE_CONTROLLER = '441266ce03e6b294e9cd3f299c4ddaad0f4f8a38683609aee08698b5a091f453'
PREVIOUS_CHECKPOINT_CONTROLLER = '22aac21746798c119e53cb4454b4b8751e476580b05fd9f6de7e41bbd5952fd5'
PREVIOUS_STORE_SHA = '446e01f18882184e53c4432aef167443cf1654c85484ad26adf8ef31492c2744'
PREVIOUS_STORE_BLOB = '316ba994f6403ef3be72d6885d06a710353d4411'
PREVIOUS_PATCH_SHA = '554a9215d3e96bc3330a08f9b6e390ac1c52c40fc48499259bd57dcdceb1bd5f'
PREVIOUS_FIXTURE_SHA = '3a8a652830f13f037e2b22ac89bdec7aa5852ee941b18a6a9f4f9aaa98efc6a3'


class LikesProfileTests(unittest.TestCase):
    def test_superseded_receipt_and_provenance_bindings_are_individually_refused(self):
        for variant, controller in (
            ('baseline', PREVIOUS_BASE_CONTROLLER),
            ('checkpoint', PREVIOUS_CHECKPOINT_CONTROLLER),
        ):
            stale = {
                'baseline_source_commit': PREVIOUS_SOURCE,
                'controller_sha256': controller,
                'store_git_blob': PREVIOUS_STORE_BLOB,
                'fixture_sha256': PREVIOUS_FIXTURE_SHA,
            }
            if variant == 'checkpoint':
                stale['patch_sha256'] = PREVIOUS_PATCH_SHA
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
                        self.assertEqual(
                            caught.exception.code,
                            'fixture_identity_invalid' if key == 'baseline_source_commit'
                            else 'fixture_source_binding_invalid',
                        )
            current_proof = source_proof(variant)
            contract.validate_provenance(current_proof, variant)
            for key, value in {
                **stale,
                'baseline_controller_sha256': PREVIOUS_BASE_CONTROLLER,
                'store_sha256': PREVIOUS_STORE_SHA,
            }.items():
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused) as caught:
                        contract.validate_provenance({**current_proof, key: value}, variant)
                    self.assertEqual(
                        caught.exception.code,
                        'source_provenance_invalid' if key == 'baseline_source_commit'
                        else 'source_provenance_binding_invalid',
                    )

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

    def test_checkpoint_experiment_edits_are_unchanged(self):
        payload = (TOOL / 'fixtures/checkpoint-drain-only.patch').read_text()
        edits = '\n'.join(
            line for line in payload.splitlines()
            if line.startswith(('+', '-')) and not line.startswith(('+++', '---'))
        )
        self.assertEqual(edits, '''+  // Checkpoint only captured, server-acknowledged identity batches. Each
+  // event still receives its own durable attempted marker before transport.
+  static const int _reviewFlushCheckpointSize = 32;
+
+    var cacheInvalidated = false;
+      }
+      if (acknowledged.length >= _reviewFlushCheckpointSize) {
+        if (!cacheInvalidated) {
+          RecallReadCache.of(api).reviewsChanged();
+          cacheInvalidated = true;
+        }
+        // A failed native acknowledgement stops this pass; it never licenses
+        // draining a later event in place of this captured identity batch.
+        await store.removeAcknowledgedReviews(
+          acknowledged,
+          ownerScope: ownerScope,
+        );
+        acknowledged.clear();
-    if (acknowledged.isNotEmpty) RecallReadCache.of(api).reviewsChanged();
+    if (acknowledged.isNotEmpty && !cacheInvalidated) {
+      RecallReadCache.of(api).reviewsChanged();
+    }''')


if __name__ == '__main__':
    unittest.main()

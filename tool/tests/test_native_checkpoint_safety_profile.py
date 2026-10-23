"""Safety-source refresh keeps the experiment fixed and refuses old receipts."""

import hashlib
from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


class SafetyProfileTests(unittest.TestCase):
    def test_checkpoint_additions_and_removal_preserve_the_original_experiment(self):
        # Bind the experiment independently of hunk offsets and source pins.
        patch = (TOOL / 'fixtures/checkpoint-drain-only.patch').read_bytes()
        delta = b''.join(
            line for line in patch.splitlines(keepends=True)
            if line[:1] in (b'+', b'-') and not line.startswith((b'+++', b'---'))
        )
        self.assertEqual(
            hashlib.sha256(delta).hexdigest(),
            '7eae2085de826d9b6b62b15371778eda26e8969c2c438181ab7330c6a07c5f06',
        )

    def test_pre_safety_profile_pins_are_individually_refused(self):
        for variant, controller in [
            ('baseline', '8a8e481360ec0cceac1d73f2bccf0dd714c8da0057aedbf930700594a9dca8b0'),
            ('checkpoint', '8cc786e245f156c75fd646c59300931479eeb6009690c6ee9c83c856197b8b07'),
        ]:
            stale = {
                'baseline_source_commit': '0836af8afb6a16e7f957263277b586d7d82f4a26',
                'controller_sha256': controller,
                'store_git_blob': 'f5b63f3eb8fff750993649791180ec41a8809eee',
                'fixture_sha256': 'd371e9780e5668409e11c805bce0153161bd45c3d750518c56928a5905f899be',
            }
            if variant == 'checkpoint':
                stale['patch_sha256'] = '5b763397f9315c456c7d585d2d01382b06de242751e49aafa427608790c91e76'
            for key, value in stale.items():
                with self.subTest(variant=variant, pin=key):
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
            for key, value in {
                'baseline_controller_sha256': '8a8e481360ec0cceac1d73f2bccf0dd714c8da0057aedbf930700594a9dca8b0',
                'store_sha256': '855f26a1428093bd81cf0745a8d079212f11cadd823d31583283b7d4e74c968b',
            }.items():
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused):
                        contract.validate_provenance(
                            {**source_proof(variant), key: value}, variant,
                        )


if __name__ == '__main__':
    unittest.main()

"""The responsive reconnect profile rejects superseded source receipts."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


class ResponsiveSyncProfileTests(unittest.TestCase):
    def test_previous_profile_cannot_qualify_current_measurements(self):
        previous_source = '1a38bb4be3ffff66da4204fa5bcb341e4c92698e'
        previous_base = 'b3d90eab96f173391ed56504dde79d631681c54d975cdacaf96031718dd48ccb'
        previous_checkpoint = '692e9616f875d96cb1a6c1b6837d17146adc72c2ab8340af9eb7704ade26b4e0'
        previous_patch = '12b80894e29cccf1fbb9366def4ebeea1ca831fe761cd0c7e2ba252b80a7f902'
        previous_fixture = 'c4d83fccb7c531e3a38e161b269dfb21ecb990825bd89d18747487e9136a50a2'
        for variant in ('baseline', 'checkpoint'):
            stale_pins = {
                'baseline_source_commit': previous_source,
                'controller_sha256': previous_base if variant == 'baseline' else previous_checkpoint,
                'fixture_sha256': previous_fixture,
            }
            if variant == 'checkpoint':
                stale_pins['patch_sha256'] = previous_patch
            for key, stale in stale_pins.items():
                with self.subTest(variant=variant, pin=key):
                    with self.assertRaises(contract.Refused):
                        contract.validate_provenance({**source_proof(variant), key: stale}, variant)
                    for count in (128, 512):
                        with self.assertRaises(contract.Refused):
                            contract.validate(
                                {**receipt(variant, count), key: stale}, variant=variant,
                                count=count, pid=101, fixture_sha=contract.FIXTURE_SHA,
                            )
            with self.subTest(variant=variant, pin='baseline_controller_sha256'):
                with self.assertRaises(contract.Refused):
                    contract.validate_provenance(
                        {**source_proof(variant), 'baseline_controller_sha256': previous_base}, variant,
                    )


if __name__ == '__main__':
    unittest.main()

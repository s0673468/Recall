"""The study-session re-pin refuses each superseded source binding."""

from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))

import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


class StudySessionProfileTests(unittest.TestCase):
    def test_superseded_safety_profile_pins_are_individually_refused(self):
        for variant, controller in [
            ('baseline', 'd5edabd6365e478aa6494a700992e3f53a5a4cfa8ca9d425ac6cbfde820bcc41'),
            ('checkpoint', '95a2209287edcca50952819ff38de51cff63792e81c9f99f0062d39e2369fedc'),
        ]:
            stale = {
                'baseline_source_commit': '6605cce2065b0149b6e7c21c03e345823d179e3b',
                'controller_sha256': controller,
                'fixture_sha256': '5453153ae23c46c25c1b4811d35e38abf195a733e7600c7669af0ae0a0393b3a',
            }
            if variant == 'checkpoint':
                stale['patch_sha256'] = '4c53cef923662f84ef89f8f58b19087c94bb2eff2bd629eb09b15df929f03f39'
            # Confirm valid new receipts/provenance before mutating one pin.
            contract.validate_provenance(source_proof(variant), variant)
            for count in (128, 512):
                contract.validate(
                    receipt(variant, count), variant=variant, count=count,
                    pid=101, fixture_sha=contract.FIXTURE_SHA,
                )
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
            with self.subTest(variant=variant, pin='baseline_controller_sha256'):
                with self.assertRaises(contract.Refused):
                    contract.validate_provenance({
                        **source_proof(variant),
                        'baseline_controller_sha256':
                            'd5edabd6365e478aa6494a700992e3f53a5a4cfa8ca9d425ac6cbfde820bcc41',
                    }, variant)


if __name__ == '__main__':
    unittest.main()

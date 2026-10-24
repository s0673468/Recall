"""A presentation state refresh must still refuse the previous byte profile."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import native_checkpoint_contract as contract
from test_native_checkpoint_cost import receipt, source_proof


class HideUndoProfileTests(unittest.TestCase):
    def test_previous_controller_and_fixture_receipts_are_refused(self):
        previous = {
            'baseline': '785c1cc281059722df498561501fd392c701b09c5572de5d0fcc76582ef576f0',
            'checkpoint': '20bdd44241c133878e100fc44a469456c54a74b77508ea7d13ed25226f214dbf',
        }
        previous_fixture = 'f849a1ea9453cabe8e3d5aad87d2b47d21405b02c8f19d6534750fd2611084fd'
        for variant, controller in previous.items():
            for key, value in (
                ('controller_sha256', controller),
                ('fixture_sha256', previous_fixture),
            ):
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


if __name__ == '__main__':
    unittest.main()

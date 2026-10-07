from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_acceptance_device import Device, target_center


class DeviceTest(unittest.TestCase):
    def test_only_campaign_emulator_targets_are_admitted(self):
        for serial, avd in [('physical-device', 'Recall_A5_1'), ('emulator-5554', 'OtherOwner')]:
            with self.subTest(serial=serial, avd=avd), self.assertRaises(ValueError):
                Device('adb', serial, avd)

    def test_taps_require_exact_unambiguous_visible_labels(self):
        node = '<node text="Good" enabled="true" bounds="[10,20][110,80]" />'
        self.assertEqual(target_center('<hierarchy>' + node + '</hierarchy>', 'Good'), (60, 50))
        for nodes in ['', node.replace('true', 'false'), node.replace('[110,80]', '[10,20]'),
                      node + node.replace('[10,20][110,80]', '[120,20][220,80]')]:
            with self.subTest(nodes=nodes), self.assertRaises(ValueError):
                target_center('<hierarchy>' + nodes + '</hierarchy>', 'Good')


if __name__ == '__main__':
    unittest.main()

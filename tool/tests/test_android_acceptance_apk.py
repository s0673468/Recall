import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_android_acceptance_apk import check_manifest


SAFE = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android"
package="com.german.health_anki_flutter.acceptance">
<application android:debuggable="true" android:label="Recall TEST" />
</manifest>'''


class AcceptanceApkTest(unittest.TestCase):
    def test_accepts_only_the_debug_fixture_identity(self):
        self.assertFalse(check_manifest(SAFE)['network_permission'])
        for unsafe in [SAFE.replace('.acceptance', ''),
                       SAFE.replace('debuggable="true"', 'debuggable="false"'),
                       SAFE.replace('Recall TEST', 'Recall')]:
            with self.subTest(unsafe=unsafe), self.assertRaises(ValueError):
                check_manifest(unsafe)

    def test_all_permission_declaration_forms_fail_closed(self):
        for tag in ['uses-permission', 'uses-permission-sdk-23', 'uses-permission-sdk-m']:
            xml = SAFE.replace('<application', f'<{tag} android:name="android.permission.INTERNET"/><application')
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                check_manifest(xml)


if __name__ == '__main__':
    unittest.main()

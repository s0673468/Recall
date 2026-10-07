#!/usr/bin/env python3
"""Verify the invented-data APK identity and network isolation before installation."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ANDROID = '{http://schemas.android.com/apk/res/android}'


def check_manifest(xml):
    manifest = ET.fromstring(xml)
    package = manifest.get('package')
    if package != 'com.german.health_anki_flutter.acceptance':
        raise ValueError('Refusing an APK outside the isolated acceptance package')
    permissions = sorted({node.get(ANDROID + 'name') for node in manifest
                          if node.tag.startswith('uses-permission')})
    if 'android.permission.INTERNET' in permissions:
        raise ValueError('Acceptance APK must not have INTERNET permission')
    app = manifest.find('application')
    if app is None or app.get(ANDROID + 'debuggable') != 'true':
        raise ValueError('Acceptance APK must be explicitly debuggable')
    if app.get(ANDROID + 'label') != 'Recall TEST':
        raise ValueError('Acceptance APK must carry the visible test label')
    return {'package': package, 'debuggable': True, 'label': 'Recall TEST',
            'permissions': permissions, 'network_permission': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--apkanalyzer', required=True)
    args = parser.parse_args()
    xml = subprocess.check_output([args.apkanalyzer, 'manifest', 'print', str(args.apk)], text=True)
    result = check_manifest(xml)
    result['sha256'] = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    result['bytes'] = args.apk.stat().st_size
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Bounded adb operations for an owned emulator and the isolated Recall fixture."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

PACKAGE = 'com.german.health_anki_flutter.acceptance'
ACTIVITY = 'com.german.health_anki_flutter.MainActivity'


def target_center(xml, label):
    """Only use an exact, enabled UI label observed in the current hierarchy."""
    matches = []
    for node in ET.fromstring(xml).iter('node'):
        if node.get('enabled') != 'true':
            continue
        if label not in (node.get('text'), node.get('content-desc')):
            continue
        bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
        if not bounds:
            continue
        left, top, right, bottom = map(int, bounds.groups())
        if right > left and bottom > top:
            matches.append(((left + right) // 2, (top + bottom) // 2))
    matches = list(dict.fromkeys(matches))
    if len(matches) != 1:
        raise ValueError(f'Expected one visible enabled target for {label!r}, found {len(matches)}')
    return matches[0]


class Device:
    def __init__(self, adb, serial, avd):
        if not re.fullmatch(r'emulator-\d+', serial):
            raise ValueError('Physical devices are outside this acceptance helper')
        if not avd.startswith('Recall_A5_'):
            raise ValueError('Require a campaign-owned Recall_A5_ AVD')
        self.command = [adb, '-s', serial]
        self.avd = avd

    def run(self, *args, binary=False):
        return subprocess.check_output(self.command + list(args), timeout=40,
                                       text=not binary)

    def guard(self):
        if self.run('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
            raise ValueError('Target did not identify as an emulator')
        if self.run('emu', 'avd', 'name').splitlines()[0] != self.avd:
            raise ValueError('AVD identity changed')
        manifest = self.run('shell', 'dumpsys', 'package', PACKAGE)
        if 'android.permission.INTERNET' in manifest or 'DEBUGGABLE' not in manifest:
            raise ValueError('Installed fixture isolation/debug guard failed')
        if not self.run('shell', 'pm', 'path', PACKAGE).startswith('package:'):
            raise ValueError('Isolated fixture is not installed')

    def hierarchy(self):
        self.run('shell', 'uiautomator', 'dump', '/sdcard/a5-fixture-window.xml')
        return self.run('exec-out', 'cat', '/sdcard/a5-fixture-window.xml')

    def snapshot(self, destination):
        destination.mkdir(mode=0o700)  # Never overwrite an earlier attempt.
        screen = self.run('exec-out', 'screencap', '-p', binary=True)
        if not screen.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('Device did not return a PNG')
        (destination / 'screen.png').write_bytes(screen)
        (destination / 'hierarchy.xml').write_text(self.hierarchy())
        # A fresh signed-out install may not have written preferences yet.
        # Preserve that gap rather than inventing an empty backend ledger.
        preferences_status = 'captured'
        try:
            preferences = self.run('exec-out', 'run-as', PACKAGE, 'cat',
                                   'shared_prefs/FlutterSharedPreferences.xml')
            (destination / 'preferences.xml').write_text(preferences)
        except subprocess.CalledProcessError as error:
            preferences_status = f'unavailable_exit_{error.returncode}'
        observed = {
            'package': PACKAGE, 'avd': self.avd,
            'font_scale': self.run('shell', 'settings', 'get', 'system', 'font_scale').strip(),
            'locale': self.run('shell', 'getprop', 'persist.sys.locale').strip(),
            'night_mode': self.run('shell', 'cmd', 'uimode', 'night').strip(),
            'accessibility_enabled': self.run('shell', 'settings', 'get', 'secure', 'accessibility_enabled').strip(),
            'accessibility_services': self.run('shell', 'settings', 'get', 'secure', 'enabled_accessibility_services').strip(),
            'size': self.run('shell', 'wm', 'size').strip(),
            'density': self.run('shell', 'wm', 'density').strip(),
            'screen_sha256': hashlib.sha256(screen).hexdigest(),
            'status': 'captured_unverified',
            'preferences_status': preferences_status,
        }
        (destination / 'observed.json').write_text(json.dumps(observed, indent=2) + '\n')
        for path in destination.iterdir():
            path.chmod(0o600)
        return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--avd', required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('launch')
    tap = commands.add_parser('tap')
    tap.add_argument('label')
    text = commands.add_parser('type-fixture')
    text.add_argument('field', choices=['email', 'password'])
    snapshot = commands.add_parser('snapshot')
    snapshot.add_argument('destination', type=Path)
    args = parser.parse_args()
    device = Device(args.adb, args.serial, args.avd)
    device.guard()
    if args.action == 'launch':
        print(device.run('shell', 'am', 'start', '-W', '-n', f'{PACKAGE}/{ACTIVITY}'))
    elif args.action == 'tap':
        x, y = target_center(device.hierarchy(), args.label)
        device.run('shell', 'input', 'tap', str(x), str(y))
    elif args.action == 'type-fixture':
        value = {'email': 'learner@example.invalid', 'password': 'invented-only'}[args.field]
        device.run('shell', 'input', 'text', value)
    else:
        print(json.dumps(device.snapshot(args.destination), indent=2))


if __name__ == '__main__':
    main()

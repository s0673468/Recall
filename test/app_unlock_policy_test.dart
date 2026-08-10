import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a restored Recall session opens without a second device lock', () {
    final app = File('lib/app/recall_app.dart').readAsStringSync();
    final dependencies = File('pubspec.yaml').readAsStringSync();
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(app, isNot(contains('BiometricUnlockGate')));
    expect(app, isNot(contains('supportsRecallBiometricUnlock')));
    expect(dependencies, isNot(contains('local_auth:')));
    expect(plist, isNot(contains('NSFaceIDUsageDescription')));
  });
}

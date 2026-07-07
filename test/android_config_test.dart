import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android launcher uses Recall branding', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:label="Recall"'));
  });

  test('release APK debug signing requires explicit opt-in', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(gradle, contains('allowDebugReleaseSigning'));
    expect(gradle, contains('gradle.taskGraph.whenReady'));
    expect(gradle, contains('allTasks.any { it.name.contains("Release") }'));
    expect(gradle, contains('signingConfig = if (hasReleaseKeystore)'));
    expect(gradle, contains('Release signing requires android/key.properties'));
  });
}

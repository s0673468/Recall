import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android launcher uses Recall branding', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:label="Recall"'));
  });

  test('release Android manifest allows network and biometric auth', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android.permission.INTERNET'));
    expect(manifest, contains('android.permission.USE_BIOMETRIC'));
  });

  test('Android activity supports local_auth biometric prompts', () {
    final activity = File(
      'android/app/src/main/kotlin/com/german/health_anki_flutter/MainActivity.kt',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(activity, contains('FlutterFragmentActivity'));
    expect(
      activity,
      isNot(contains('import io.flutter.embedding.android.FlutterActivity')),
    );
    expect(gradle, contains('minSdk = 24'));
  });

  test('Android launch themes are AppCompat for local_auth', () {
    for (final path in [
      'android/app/src/main/res/values/styles.xml',
      'android/app/src/main/res/values-night/styles.xml',
    ]) {
      final styles = File(path).readAsStringSync();

      expect(styles, contains('name="LaunchTheme"'));
      expect(styles, contains('parent="Theme.AppCompat.DayNight.NoActionBar"'));
      expect(styles, isNot(contains('@android:style/Theme.Light.NoTitleBar')));
      expect(styles, isNot(contains('@android:style/Theme.Black.NoTitleBar')));
    }
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

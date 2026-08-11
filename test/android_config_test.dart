import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  final appBuild = File('android/app/build.gradle.kts');
  final mainActivity = File(
    'android/app/src/main/kotlin/com/german/health_anki_flutter/'
    'MainActivity.kt',
  );
  final reminderReceiver = File(
    'android/app/src/main/kotlin/com/german/health_anki_flutter/'
    'RecallReminderReceiver.kt',
  );
  final widgetProvider = File(
    'android/app/src/main/kotlin/com/german/health_anki_flutter/'
    'RecallWidgetProvider.kt',
  );
  final contracts = File(
    'android/app/src/main/kotlin/com/german/health_anki_flutter/'
    'RecallContracts.kt',
  );
  final diagnostics = File(
    'android/app/src/main/kotlin/com/german/health_anki_flutter/'
    'RecallOperationalDiagnostics.kt',
  );
  final strings = File('android/app/src/main/res/values/strings.xml');
  final shortcuts = File('android/app/src/main/res/xml/shortcuts.xml');
  final widgetInfo = File(
    'android/app/src/main/res/xml/recall_widget_info.xml',
  );
  final icon = File('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png');
  final dartMain = File('lib/main.dart');

  test('Android host preserves the historical Recall application identity', () {
    expect(
      manifest.existsSync(),
      isTrue,
      reason: 'Android manifest is required',
    );
    expect(
      appBuild.existsSync(),
      isTrue,
      reason: 'Android app build is required',
    );
    expect(
      mainActivity.existsSync(),
      isTrue,
      reason: 'MainActivity is required',
    );

    final build = appBuild.readAsStringSync();
    expect(build, contains('namespace = "com.german.health_anki_flutter"'));
    expect(build, contains('applicationId = "com.german.health_anki_flutter"'));
    expect(build, contains('compileSdk = flutter.compileSdkVersion'));
    expect(build, contains('targetSdk = flutter.targetSdkVersion'));
    expect(build, contains('minSdk = 24'));
  });

  test('Android manifest is private, edge-to-edge, and deep-link aware', () {
    final xml = manifest.readAsStringSync();

    expect(xml, contains('android:label="@string/app_name"'));
    expect(
      strings.readAsStringSync(),
      contains('<string name="app_name">Recall</string>'),
    );
    expect(xml, contains('android:allowBackup="false"'));
    expect(xml, contains('android:usesCleartextTraffic="false"'));
    expect(xml, contains('android:enableOnBackInvokedCallback="true"'));
    expect(xml, contains('android.permission.INTERNET'));
    expect(xml, contains('android.permission.POST_NOTIFICATIONS'));
    expect(xml, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(xml, contains('android:scheme="recall"'));
    expect(xml, contains('android:host="study"'));
    expect(
      RegExp(
        r'android\.permission\.USE_BIOMETRIC"\s+tools:node="remove"',
      ).hasMatch(xml),
      isTrue,
    );
    expect(
      RegExp(
        r'android\.permission\.USE_CREDENTIALS"\s+tools:node="remove"',
      ).hasMatch(xml),
      isTrue,
    );
    expect(
      RegExp(
        r'android\.permission\.CREDENTIAL_MANAGER_SET_ORIGIN"\s+'
        r'tools:node="remove"',
      ).hasMatch(xml),
      isTrue,
    );
    expect(xml, isNot(contains('android.permission.SCHEDULE_EXACT_ALARM')));

    final bootstrap = dartMain.readAsStringSync();
    expect(bootstrap, contains('SystemUiMode.edgeToEdge'));
    expect(bootstrap, contains('statusBarColor: Colors.transparent'));
    expect(bootstrap, contains('systemNavigationBarColor: Colors.transparent'));
  });

  test('Android native bridges expose only the maintained Recall channels', () {
    final kotlin = [
      mainActivity.readAsStringSync(),
      contracts.readAsStringSync(),
      diagnostics.readAsStringSync(),
    ].join('\n');

    expect(kotlin, contains('com.german.ankiReview/studyReminder'));
    expect(kotlin, contains('com.german.ankiReview/widget'));
    expect(kotlin, contains('com.german.ankiReview/operationalDiagnostics'));
    expect(kotlin, contains('requestPermission'));
    expect(kotlin, contains('onCapabilitiesChanged'));
    expect(kotlin, contains('NET_CAPABILITY_VALIDATED'));
    expect(kotlin, contains('updatedAtEpochMs'));
    expect(kotlin, contains('operational-event/v2'));
  });

  test('Android reminder and widget remain aggregate-only', () {
    expect(reminderReceiver.existsSync(), isTrue);
    expect(widgetProvider.existsSync(), isTrue);
    expect(shortcuts.existsSync(), isTrue);
    expect(widgetInfo.existsSync(), isTrue);

    final nativeSources = [
      reminderReceiver.readAsStringSync(),
      widgetProvider.readAsStringSync(),
      mainActivity.readAsStringSync(),
      contracts.readAsStringSync(),
      diagnostics.readAsStringSync(),
    ].join('\n');
    expect(nativeSources, contains('recall://study'));
    expect(nativeSources, contains('due_count'));
    for (final forbidden in [
      'SUPABASE_URL',
      'SUPABASE_ANON_KEY',
      'review_log',
      'card_id',
      'user_id',
    ]) {
      expect(nativeSources, isNot(contains(forbidden)));
    }
    expect(nativeSources, isNot(matches(RegExp(r'''["'](?:front|back)["']'''))));
  });

  test('Android launcher icon is opaque and full xxxhdpi resolution', () {
    expect(
      icon.existsSync(),
      isTrue,
      reason: 'branded launcher icon is required',
    );
    final bytes = icon.readAsBytesSync();
    final data = ByteData.sublistView(bytes);

    expect(data.getUint32(16, Endian.big), 192);
    expect(data.getUint32(20, Endian.big), 192);
    expect(bytes[24], 8, reason: 'The launcher should use 8-bit channels.');
    expect(bytes[25], anyOf(2, 6), reason: 'The launcher must be RGB or RGBA.');
  });
}

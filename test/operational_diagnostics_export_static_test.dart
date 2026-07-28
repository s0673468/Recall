import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS diagnostics exporter is registered and compiled into Runner', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(
      appDelegate,
      contains('RecallOperationalDiagnosticsPlugin.register'),
    );
    expect(
      project,
      contains('RecallOperationalDiagnosticsPlugin.swift in Sources'),
    );
    expect(main, contains('MethodChannelOperationalEventExporter'));
  });

  test('native mirror pins privacy, size, and atomic-write contracts', () {
    final source = File(
      'ios/Runner/RecallOperationalDiagnosticsPlugin.swift',
    ).readAsStringSync();

    expect(source, contains('RecallDiagnostics'));
    expect(source, contains('operational-events-v2.json'));
    expect(source, contains('64 * 1024'));
    expect(source, contains('0o700'));
    expect(source, contains('0o600'));
    expect(source, contains('completeUntilFirstUserAuthentication'));
    expect(source, contains('isExcludedFromBackup = true'));
    expect(source, contains('replaceItemAt'));
    expect(source, isNot(contains('UserDefaults')));
    for (final forbidden in [
      'recall_snapshot_v1',
      'recall_outbox_v1',
      'flag_outbox_v1',
      'recall_prefs_v1',
    ]) {
      expect(source, isNot(contains(forbidden)));
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final infoPlist = File('ios/Runner/Info.plist');
  final project = File('ios/Runner.xcodeproj/project.pbxproj');
  final runnerEntitlements = File('ios/Runner/Runner.entitlements');
  final widgetEntitlements = File('ios/RecallWidget/RecallWidget.entitlements');
  final widgetSource = File('ios/RecallWidget/RecallWidget.swift');
  final widgetInfo = File('ios/RecallWidget/Info.plist');
  final widgetPlugin = File('ios/Runner/RecallWidgetPlugin.swift');

  test('Recall ships an aggregate-only WidgetKit due-count extension', () {
    expect(runnerEntitlements.existsSync(), isTrue);
    expect(widgetEntitlements.existsSync(), isTrue);
    expect(widgetSource.existsSync(), isTrue);
    expect(widgetInfo.existsSync(), isTrue);
    expect(widgetPlugin.existsSync(), isTrue);

    const appGroup = 'group.com.german.ankiReview';
    expect(runnerEntitlements.readAsStringSync(), contains(appGroup));
    expect(widgetEntitlements.readAsStringSync(), contains(appGroup));

    final plist = infoPlist.readAsStringSync();
    expect(plist, contains('<string>recall</string>'));

    final pbxproj = project.readAsStringSync();
    expect(pbxproj, contains('RecallWidget.appex'));
    expect(pbxproj, contains('com.german.ankiReview.RecallWidget'));
    expect(pbxproj, contains('com.apple.product-type.app-extension'));
    expect(pbxproj, contains('Embed App Extensions'));
    expect(pbxproj, contains('IPHONEOS_DEPLOYMENT_TARGET = 18.0;'));

    final swift = widgetSource.readAsStringSync();
    final plugin = widgetPlugin.readAsStringSync();
    expect(swift, contains('due_count'));
    expect(swift, contains('updated_at'));
    expect(swift, contains('StartStudyIntent'));
    expect(swift, contains('recall://study'));
    for (final forbidden in [
      'SUPABASE_URL',
      'anon_key',
      'review_log',
      'card_id',
      'front',
      'back',
    ]) {
      expect(swift, isNot(contains(forbidden)));
      expect(plugin, isNot(contains(forbidden)));
    }
  }, tags: const ['apple-mobile']);

  test('iOS release signing authorizes the private session Keychain', () {
    final entitlements = runnerEntitlements.readAsStringSync();
    final pbxproj = project.readAsStringSync();

    expect(entitlements, contains('<key>keychain-access-groups</key>'));
    expect(
      entitlements,
      contains(r'$(AppIdentifierPrefix)com.german.ankiReview'),
    );
    expect(
      pbxproj,
      contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'),
    );
  }, tags: const ['apple-mobile']);
}

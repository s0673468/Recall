import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final infoPlist = File('ios/Runner/Info.plist');
  final project = File('ios/Runner.xcodeproj/project.pbxproj');
  final runnerEntitlements = File('ios/Runner/Runner.entitlements');
  final widgetEntitlements = File('ios/RecallWidget/RecallWidget.entitlements');
  final widgetSource = File('ios/RecallWidget/RecallWidget.swift');
  final widgetInfo = File('ios/RecallWidget/Info.plist');
  final widgetPlugin = File('ios/Runner/RecallWidgetPlugin.swift');
  final icon = File(
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/'
    'Icon-App-1024x1024@1x.png',
  );

  test('Recall ships an iOS 16 portrait runner with Face ID disclosure', () {
    expect(infoPlist.existsSync(), isTrue, reason: 'iOS runner is required');
    expect(project.existsSync(), isTrue, reason: 'Xcode project is required');

    final plist = infoPlist.readAsStringSync();
    expect(plist, contains('<string>Recall</string>'));
    expect(plist, contains('<key>NSFaceIDUsageDescription</key>'));
    expect(plist, contains('Unlock Recall with Face ID'));

    final phoneOrientations = RegExp(
      r'<key>UISupportedInterfaceOrientations</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist)?.group(1);
    expect(phoneOrientations, contains('UIInterfaceOrientationPortrait'));
    expect(
      phoneOrientations,
      isNot(contains('UIInterfaceOrientationLandscape')),
    );

    final pbxproj = project.readAsStringSync();
    expect(
      pbxproj,
      contains('PRODUCT_BUNDLE_IDENTIFIER = com.german.ankiReview;'),
    );
    expect(pbxproj, contains('IPHONEOS_DEPLOYMENT_TARGET = 16.0;'));
    expect(icon.existsSync(), isTrue, reason: 'branded app icon is required');
  });

  test('iOS marketing icon is opaque and full resolution', () {
    final bytes = icon.readAsBytesSync();
    final data = ByteData.sublistView(bytes);

    expect(data.getUint32(16, Endian.big), 1024);
    expect(data.getUint32(20, Endian.big), 1024);
    expect(bytes[24], 8, reason: 'The source icon should use 8-bit channels.');
    expect(bytes[25], 2, reason: 'PNG color type 2 is opaque RGB.');
  });

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
  });
}

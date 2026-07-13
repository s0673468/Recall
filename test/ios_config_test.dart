import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final infoPlist = File('ios/Runner/Info.plist');
  final project = File('ios/Runner.xcodeproj/project.pbxproj');
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
}

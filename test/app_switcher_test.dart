import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/vendored/src/navigation/app_switcher.dart';

void main() {
  test('app switcher exposes only active Health web apps', () {
    expect(HealthWebApp.all.map((app) => (app.name, app.subpath)), [
      ('Dashboard', ''),
      ('Track', 'track/'),
      ('Recall', 'recall/'),
    ]);
  });

  test('suite root resolves from Recall without a hardcoded host', () {
    expect(
      suiteRootFromBaseUri('https://example.test/Health/recall/'),
      'https://example.test/Health/',
    );
  });
}

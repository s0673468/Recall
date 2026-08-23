import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/vendored/src/navigation/app_switcher.dart';
import 'package:health_anki_flutter/vendored/src/navigation/app_switcher_platform_stub.dart'
    as native_platform;

void main() {
  test('default public web exposes no dead Track destination', () {
    const recallBase = 'https://s0673468.github.io/Recall/';

    expect(appDestinationFromBaseUri(HealthWebApp.track, recallBase), isNull);
    expect(
      appDestinationFromBaseUri(HealthWebApp.recall, recallBase),
      recallBase,
    );
    expect(supportsAppSwitcher(isWeb: true, hasWebSibling: false), isFalse);
  });

  test('native Recall starts route resolution from its deployed web app', () {
    expect(
      native_platform.documentBaseUri(),
      'https://s0673468.github.io/Recall/',
    );
  });

  test('Pages base path and installed-app identity stay standalone', () {
    final workflow = File('.github/workflows/pages.yml').readAsStringSync();
    final manifest = File('web/manifest.json').readAsStringSync();

    expect(workflow, contains('--base-href /Recall/'));
    expect(manifest, contains('"id": "/Recall/"'));
    expect(manifest, isNot(contains('/Health/recall/')));
  });

  test('custom suite and Recall roots remain configurable', () {
    const current = 'https://preview.example.test/apps/recall/';
    const health = 'https://preview.example.test/family/';
    const recall = 'https://preview.example.test/study/';

    expect(
      appDestinationFromBaseUri(
        HealthWebApp.track,
        current,
        trackWebRoot: '${health}today/',
        recallWebRoot: recall,
      ),
      '${health}today/',
    );
    expect(
      appDestinationFromBaseUri(
        HealthWebApp.recall,
        current,
        healthSuiteRoot: health,
        recallWebRoot: recall,
      ),
      recall,
    );
    expect(
      appDestinationFromBaseUri(
        HealthWebApp.track,
        current,
        healthSuiteRoot: health,
      ),
      '${health}track/',
    );
    expect(supportsAppSwitcher(isWeb: true, hasWebSibling: true), isTrue);
  });

  test('the maintained switcher topology is Track plus Recall', () {
    expect(HealthWebApp.all.map((app) => app.name), ['Track', 'Recall']);
    expect(HealthWebApp.track.preferredNativeUri, 'track://today');
  });

  test(
    'native Track launch falls back only to an explicit HTTPS URL',
    () async {
      final attempted = <Uri>[];

      await native_platform.assignLocation(
        'https://preview.example.test/track/',
        preferredNativeUrl: HealthWebApp.track.preferredNativeUri,
        launcher: (uri) async {
          attempted.add(uri);
          return uri.scheme == 'https';
        },
      );

      expect(attempted.map((uri) => uri.toString()), [
        'track://today',
        'https://preview.example.test/track/',
      ]);
    },
  );

  test('native Track launch stops after the installed app opens', () async {
    final attempted = <Uri>[];

    await native_platform.assignLocation(
      'https://preview.example.test/track/',
      preferredNativeUrl: HealthWebApp.track.preferredNativeUri,
      launcher: (uri) async {
        attempted.add(uri);
        return true;
      },
    );

    expect(attempted.map((uri) => uri.toString()), ['track://today']);
  });

  test(
    'native default never falls through to an unconfigured web URL',
    () async {
      final attempted = <Uri>[];

      await native_platform.assignLocation(
        null,
        preferredNativeUrl: HealthWebApp.track.preferredNativeUri,
        launcher: (uri) async {
          attempted.add(uri);
          return false;
        },
      );

      expect(attempted.map((uri) => uri.toString()), ['track://today']);
    },
  );

  test('native fallback rejects a non-HTTPS Track URL', () async {
    final attempted = <Uri>[];

    await native_platform.assignLocation(
      'http://preview.example.test/track/',
      preferredNativeUrl: HealthWebApp.track.preferredNativeUri,
      launcher: (uri) async {
        attempted.add(uri);
        return false;
      },
    );

    expect(attempted.map((uri) => uri.toString()), ['track://today']);
  });

  testWidgets('current app is selected and cannot navigate to itself', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppSwitcher(current: HealthWebApp.recall)),
      ),
    );

    final recall = tester.widget<InkWell>(
      find.byKey(const Key('app_switcher_recall')),
    );
    expect(recall.onTap, isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  test('native Android keeps the installed-app switcher surface', () {
    expect(
      supportsAppSwitcher(isWeb: false, targetPlatform: TargetPlatform.android),
      isTrue,
    );
  });
}

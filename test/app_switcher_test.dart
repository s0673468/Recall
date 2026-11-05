
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

}

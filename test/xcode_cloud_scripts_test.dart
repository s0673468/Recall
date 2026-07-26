import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repositoryRoot = Directory.current.path;
  final postCloneScript = '$repositoryRoot/ios/ci_scripts/ci_post_clone.sh';
  final postBuildScript =
      '$repositoryRoot/ios/ci_scripts/ci_post_xcodebuild.sh';

  test('post-clone prepares a pinned, secret-backed Flutter archive', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'recall-xcode-cloud-test-',
    );
    addTearDown(() => sandbox.delete(recursive: true));

    final checkout = Directory('${sandbox.path}/checkout')
      ..createSync(recursive: true);
    final flutterRoot = Directory('${sandbox.path}/flutter')
      ..createSync(recursive: true);
    final flutterBin = File('${flutterRoot.path}/bin/flutter');
    flutterBin.parent.createSync(recursive: true);
    flutterBin.writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$*" >> "\$RECALL_CI_CALL_LOG"
''');
    await Process.run('/bin/chmod', ['+x', flutterBin.path]);

    final callLog = File('${sandbox.path}/flutter-calls.log');
    const runtimeConfig = {
      'SUPABASE_URL': 'https://example.supabase.co',
      'SUPABASE_ANON_KEY': 'anon-test-value',
    };
    final result = await Process.run(
      '/bin/bash',
      [postCloneScript],
      environment: {
        ...Platform.environment,
        'CI_BUILD_NUMBER': '42',
        'CI_WORKSPACE': sandbox.path,
        'RECALL_CI_CALL_LOG': callLog.path,
        'RECALL_CI_FLUTTER_ROOT': flutterRoot.path,
        'RECALL_CI_REPO_ROOT': checkout.path,
        'RECALL_SUPABASE_CONFIG_B64': base64Encode(
          utf8.encode(jsonEncode(runtimeConfig)),
        ),
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, isNot(contains('anon-test-value')));
    expect(result.stderr, isNot(contains('anon-test-value')));

    final decoded = jsonDecode(
      File('${checkout.path}/config/supabase.local.json').readAsStringSync(),
    );
    expect(decoded, runtimeConfig);

    final calls = callLog.readAsLinesSync();
    expect(calls, contains('config --enable-ios --no-cli-animations'));
    expect(calls, contains('pub get'));
    expect(
      calls.singleWhere((call) => call.startsWith('build ios ')),
      allOf(
        contains('--config-only'),
        contains('--release'),
        contains('--no-codesign'),
        contains('--build-number=42'),
        contains(
          '--dart-define-from-file='
          '${checkout.path}/config/supabase.local.json',
        ),
      ),
    );
  });

  test(
    'post-clone fails closed without the protected runtime config',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'recall-xcode-cloud-missing-secret-',
      );
      addTearDown(() => sandbox.delete(recursive: true));

      final result = await Process.run(
        '/bin/bash',
        [postCloneScript],
        environment: {
          ...Platform.environment,
          'CI_BUILD_NUMBER': '7',
          'CI_WORKSPACE': sandbox.path,
          'RECALL_CI_REPO_ROOT': '${sandbox.path}/checkout',
        }..remove('RECALL_SUPABASE_CONFIG_B64'),
      );

      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}${result.stderr}',
        contains('RECALL_SUPABASE_CONFIG_B64 is required'),
      );
    },
  );

  test('post-clone rejects a non-numeric cloud build number', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'recall-xcode-cloud-build-number-',
    );
    addTearDown(() => sandbox.delete(recursive: true));

    final result = await Process.run(
      '/bin/bash',
      [postCloneScript],
      environment: {
        ...Platform.environment,
        'CI_BUILD_NUMBER': 'not-a-number',
        'CI_WORKSPACE': sandbox.path,
        'RECALL_CI_REPO_ROOT': '${sandbox.path}/checkout',
        'RECALL_SUPABASE_CONFIG_B64': base64Encode(
          utf8.encode(
            jsonEncode({
              'SUPABASE_URL': 'https://example.supabase.co',
              'SUPABASE_ANON_KEY': 'anon-test-value',
            }),
          ),
        ),
      },
    );

    expect(result.exitCode, isNot(0));
    expect(
      '${result.stdout}${result.stderr}',
      contains('CI_BUILD_NUMBER must be a positive integer'),
    );
  });

  test('post-build removes the reconstructed runtime config', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'recall-xcode-cloud-cleanup-',
    );
    addTearDown(() => sandbox.delete(recursive: true));

    final checkout = Directory('${sandbox.path}/checkout');
    final config = File('${checkout.path}/config/supabase.local.json');
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('sensitive build input');

    final result = await Process.run(
      '/bin/bash',
      [postBuildScript],
      environment: {
        ...Platform.environment,
        'RECALL_CI_REPO_ROOT': checkout.path,
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(config.existsSync(), isFalse);
  });
}

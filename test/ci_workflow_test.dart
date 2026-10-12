import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final ci = File('.github/workflows/ci.yml');
  final pages = File('.github/workflows/pages.yml');
  final setupFlutter = File('.github/actions/setup-flutter/action.yml');
  final flutterVersion = File('.flutter-version');
  final metadata = File('.metadata');

  test('supported build lanes use the same pinned Flutter release', () {
    expect(flutterVersion.readAsStringSync().trim(), '3.47.1');
    expect(setupFlutter.readAsStringSync(), contains('.flutter-version'));
    expect(
      setupFlutter.readAsStringSync(),
      contains('./tool/flutterw --version'),
    );
    expect(
      metadata.readAsStringSync(),
      contains('revision: "6655482ec06e547f90abf8ae7590466f4415978d"'),
    );
  });

  test('historical Xcode setup uses the pinned Flutter release', () {
    final setup = File('ios/ci_scripts/ci_post_clone.sh').readAsStringSync();
    expect(setup, contains('.flutter-version'));
    expect(setup, contains('tool/flutterw'));
  }, tags: const ['apple-mobile']);

  test('Apple jobs stay disabled while Android and web keep their gate', () {
    final workflow = ci.readAsStringSync();
    for (final job in ['ios-native', 'testflight-helper']) {
      final block = workflow
          .split('\n  $job:\n')
          .last
          .split(RegExp(r'\n  [a-z0-9-]+:\n'))
          .first;
      expect(
        block,
        contains('\n    if: false\n'),
        reason: '$job must stay retired',
      );
    }
    for (final job in ['flutter', 'android-native']) {
      final block = workflow
          .split('\n  $job:\n')
          .last
          .split(RegExp(r'\n  [a-z0-9-]+:\n'))
          .first;
      expect(block, contains('runs-on: ubuntu-latest'));
      expect(block, isNot(contains('if: false')));
      expect(block, contains('contents: read'));
    }
    expect(workflow, contains('--exclude-tags apple-mobile'));
    final defaults = File('dart_test.yaml').readAsStringSync();
    expect(defaults, contains('tags:\n  apple-mobile:\n    skip:'));
    expect(defaults, contains('Recall supports Android and web'));
  });

  test('full analysis excludes only the retired Apple test files', () {
    final options = File('analysis_options.yaml').readAsStringSync();
    final exclusions = RegExp(
      r'^    - (.+)$',
      multiLine: true,
    ).allMatches(options).map((match) => match.group(1)!).toList();
    expect(
      exclusions.where((path) => path.startsWith('test/')),
      unorderedEquals([
        'test/ios_config_test.dart',
        'test/xcode_cloud_scripts_test.dart',
        'test/testflight_build_script_test.dart',
        'test/operational_diagnostics_export_static_test.dart',
      ]),
    );
    expect(exclusions, isNot(contains('lib/**')));
    expect(exclusions, isNot(contains('test/**')));
  });

  test('CI preserves maintained suites and historical check contexts', () {
    final workflow = ci.readAsStringSync();

    expect(workflow, contains('actions/setup-python@v7'));
    expect(workflow, isNot(contains('actions/setup-python@v6')));

    for (final job in [
      'concept-sync-safety:',
      'flutter:',
      'android-native:',
      'flag-report:',
      'testflight-helper:',
      'fsrs-optimizer:',
      'ios-native:',
    ]) {
      expect(workflow, contains('\n  $job'));
    }

    for (final command in [
      'python -m unittest discover -s tools/recall_sync/tests',
      'python -m unittest discover -s tools/flag_report/tests',
      'python -m unittest discover -s scripts/tests',
      'python -m unittest discover -s tools/fsrs_optimize/tests',
      'python3 tool/run_ios_tests.py --',
      './tool/flutterw build web --release',
    ]) {
      expect(workflow, contains(command));
    }

    expect(
      workflow,
      contains('pip install -r tools/flag_report/requirements.txt'),
    );
    expect(
      workflow,
      contains('pip install -r tools/fsrs_optimize/requirements.txt'),
    );
    expect(
      workflow,
      contains(r'$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager'),
    );
    expect(workflow, isNot(contains('run: sdkmanager')));
  });

  test('public workflows stay on GitHub-hosted runners', () {
    final workflows = '${ci.readAsStringSync()}\n${pages.readAsStringSync()}';

    expect(workflows, isNot(contains('runs-on: self-hosted')));
    expect(workflows, contains('runs-on: ubuntu-latest'));
    expect(workflows, contains('runs-on: macos-latest'));
  });

  test('Pages deploys protected main without deprecated PWA flags', () {
    final workflow = pages.readAsStringSync();

    expect(workflow, contains('push:\n    branches: [main]'));
    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, isNot(contains('--pwa-strategy')));
    expect(workflow, contains('web/tool/stamp_service_worker.py'));
    expect(workflow, contains('github.sha'));
    expect(workflow, contains('actions/configure-pages@v6'));
    expect(workflow, contains('actions/upload-pages-artifact@v5'));
    expect(workflow, contains('actions/deploy-pages@v5'));
  });
}

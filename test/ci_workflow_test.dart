import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final ci = File('.github/workflows/ci.yml');
  final pages = File('.github/workflows/pages.yml');
  final setupFlutter = File('.github/actions/setup-flutter/action.yml');
  final xcodeCloudSetup = File('ios/ci_scripts/ci_post_clone.sh');
  final metadata = File('.metadata');

  test('every build lane uses the same pinned Flutter release', () {
    expect(setupFlutter.readAsStringSync(), contains('default: "3.47.1"'));
    expect(xcodeCloudSetup.readAsStringSync(), contains(':-3.47.1}'));
    expect(
      metadata.readAsStringSync(),
      contains('revision: "6655482ec06e547f90abf8ae7590466f4415978d"'),
    );
  });

  test('CI gives each maintained suite an owned lane', () {
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
      'xcodebuild test',
      'flutter build web --release',
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

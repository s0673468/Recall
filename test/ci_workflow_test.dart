import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final ci = File('.github/workflows/ci.yml');
  final pages = File('.github/workflows/pages.yml');

  test('CI preserves maintained suites and historical check contexts', () {
    final workflow = ci.readAsStringSync();

    expect(workflow, contains('actions/setup-python@v7'));
    expect(workflow, isNot(contains('actions/setup-python@v6')));

    for (final job in [
      'concept-sync-safety:',
      'flutter:',
      'flutter-checks:',
      'flutter-tests:',
      'android-build:',
      'android-gradle-checks:',
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

  test('required android-native check fails unless both lanes succeed', () {
    final gate = ci
        .readAsStringSync()
        .split('\n  android-native:\n')
        .last
        .split(RegExp(r'\n  [a-z0-9-]+:\n'))
        .first;
    // Branch protection requires the android-native context. Without
    // `always()` a failed lane would skip the gate, which counts as passing.
    expect(gate, contains('\n    if: always()\n'));
    expect(gate, contains('needs: [android-build, android-gradle-checks]'));
    expect(gate, contains(r'${{ needs.android-build.result }}'));
    expect(gate, contains(r'${{ needs.android-gradle-checks.result }}'));
    expect(
      gate,
      contains(
        r'[[ "$BUILD_RESULT" == success && "$CHECKS_RESULT" == success ]]',
      ),
    );
    expect(gate, contains('runs-on: ubuntu-latest'));
  });

  test('Flutter tests run as hosted file shards behind the required check', () {
    String job(String name) => ci
        .readAsStringSync()
        .split('\n  $name:\n')
        .last
        .split(RegExp(r'\n  [a-z0-9-]+:\n'))
        .first;

    final shards = job('flutter-tests');
    // Built-in --total-shards slices tests inside every file, so each shard
    // would still compile the whole suite. Shards are whole files instead.
    expect(shards, isNot(contains('--total-shards')));
    expect(shards, isNot(contains('--shard-index')));
    expect(
      shards,
      contains(
        'python3 tool/flutter_test_shards.py --total "\$SHARD_TOTAL" '
        '--index "\$SHARD_INDEX"',
      ),
    );
    expect(shards, contains('--concurrency=4'));
    expect(shards, contains('fail-fast: false'));
    final total = int.parse(
      RegExp(r'SHARD_TOTAL: (\d+)').firstMatch(shards)!.group(1)!,
    );
    final matrix = RegExp(r'shard: \[([0-9, ]+)\]').firstMatch(shards)!;
    expect(
      matrix.group(1)!.split(',').map((s) => int.parse(s.trim())),
      orderedEquals(List.generate(total, (i) => i)),
      reason: 'the matrix must run every shard index exactly once',
    );
    expect(shards, contains(r'SHARD_INDEX: ${{ matrix.shard }}'));

    // The required `flutter` context must fail unless every lane succeeded;
    // a plain `needs` would be skipped on failure, which counts as passing.
    final gate = job('flutter');
    expect(gate, contains('\n    if: always()\n'));
    expect(gate, contains('needs: [flutter-checks, flutter-tests]'));
    expect(gate, contains(r'${{ needs.flutter-checks.result }}'));
    expect(gate, contains(r'${{ needs.flutter-tests.result }}'));
    expect(
      gate,
      contains(
        r'[[ "$CHECKS_RESULT" == success && "$TESTS_RESULT" == success ]]',
      ),
    );
    expect(gate, contains('runs-on: ubuntu-latest'));
    expect(gate, contains('contents: read'));
  });

  test('public workflows stay on GitHub-hosted runners', () {
    final workflows = '${ci.readAsStringSync()}\n${pages.readAsStringSync()}';

    expect(workflows, isNot(contains('runs-on: self-hosted')));
    expect(workflows, contains('runs-on: ubuntu-latest'));
    expect(workflows, contains('runs-on: macos-latest'));
  });

  test('Pages publisher stays inert for main and manual triggers', () {
    final workflow = pages.readAsStringSync();

    expect(workflow, contains('name: Deploy Recall to Pages'));
    expect(workflow, contains('push:\n    branches: [main]'));
    expect(workflow, contains('workflow_dispatch:'));
    final jobs = RegExp(
      r'^  ([a-z0-9-]+):$',
      multiLine: true,
    ).allMatches(workflow.split('\njobs:\n').last);
    expect(jobs.map((match) => match.group(1)), orderedEquals(['deploy']));
    expect(workflow, contains('deploy:\n    if: false\n'));
    expect(workflow, contains('contents: read'));
    expect(workflow, isNot(contains('uses:')));
    expect(workflow, isNot(contains('write')));
    expect(workflow, isNot(contains('secrets.')));
    expect(workflow, isNot(contains('github-pages')));
    expect(workflow, isNot(contains('build web')));
    expect(workflow, isNot(contains('build/web')));
    expect(workflow, isNot(contains('stamp_service_worker')));
    expect(workflow, isNot(contains('actions/configure-pages')));
    expect(workflow, isNot(contains('actions/upload-pages-artifact')));
    expect(workflow, isNot(contains('actions/deploy-pages')));
  });
}

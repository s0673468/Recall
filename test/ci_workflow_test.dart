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

  test('Apple jobs stay disabled while Android keeps its gate', () {
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
    // The required `flutter` context gates these two; see the shard test below.
    const maintainedCommands = {
      'flutter-checks': [
        './tool/flutterw analyze',
        "python3 -m unittest discover -s tool/tests -p 'test_*.py'",
      ],
      'flutter-tests': [
        './tool/flutterw test --reporter=failures-only --exclude-tags apple-mobile',
      ],
      'android-build': [
        './tool/flutterw build apk --debug --no-pub',
        'python3 tool/check_android_release_policy.py',
      ],
      // Split from the build so unit tests and lint run beside it.
      'android-gradle-checks': [
        ':app:testDebugUnitTest :app:lintDebug',
        ':app:assembleDebugAndroidTest --no-daemon --max-workers=2',
      ],
    };
    for (final job in maintainedCommands.keys) {
      final block = workflow
          .split('\n  $job:\n')
          .last
          .split(RegExp(r'\n  [a-z0-9-]+:\n'))
          .first;
      expect(block, contains('runs-on: ubuntu-latest'));
      expect(block, isNot(contains('if: false')));
      expect(block, contains('contents: read'));
      for (final command in maintainedCommands[job]!) {
        expect(block, contains(command), reason: '$job must keep $command');
      }
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

  test('hosted Android lanes restore the Gradle cache', () {
    for (final job in ['android-build', 'android-gradle-checks']) {
      final block = ci
          .readAsStringSync()
          .split('\n  $job:\n')
          .last
          .split(RegExp(r'\n  [a-z0-9-]+:\n'))
          .first;
      expect(block, contains('uses: actions/setup-java@v5'), reason: job);
      expect(block, contains('cache: gradle'), reason: job);
    }
  });

  test('only the disposable hosted lane shares a Gradle daemon', () {
    // The release-policy probes run four Gradle builds. On a hosted VM that is
    // discarded after the job they reuse the daemon warmed by the debug build;
    // local and compute-host runs stay daemonless and leave no JVM running.
    final workflow = ci.readAsStringSync();
    final android = workflow
        .split('\n  android-build:\n')
        .last
        .split(RegExp(r'\n  [a-z0-9-]+:\n'))
        .first;
    expect(android, contains('RECALL_GRADLE_DAEMON: "1"'));
    expect('RECALL_GRADLE_DAEMON'.allMatches(workflow), hasLength(1));
    expect(workflow, isNot(contains('runs-on: self-hosted')));
    final policy = File(
      'tool/check_android_release_policy.py',
    ).readAsStringSync();
    expect(
      policy,
      contains(
        "'--daemon' if environment.get('RECALL_GRADLE_DAEMON') == '1' "
        "else '--no-daemon'",
      ),
    );
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

  test('Flutter CI does not build or stamp the retired PWA', () {
    final workflow = ci.readAsStringSync();

    expect(workflow, isNot(contains('build web')));
    expect(workflow, isNot(contains('web/tool/tests')));
    expect(workflow, isNot(contains('web/tool/stamp_service_worker.py')));
    expect(workflow, isNot(contains('build/web')));
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

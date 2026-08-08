import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flag report Python unit tests pass', () async {
    final result = await Process.run('python3', [
      '-m',
      'unittest',
      'discover',
      '-s',
      'tools/flag_report/tests',
      '-p',
      'test_*.py',
      '-v',
    ]);

    expect(
      result.exitCode,
      0,
      reason:
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
  });
}

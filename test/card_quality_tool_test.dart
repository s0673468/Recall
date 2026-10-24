import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('synthetic card quality Python tests pass', () async {
    final result = await Process.run('python3', [
      '-m',
      'unittest',
      'discover',
      '-s',
      'tools/card_quality/tests',
    ]);

    expect(
      result.exitCode,
      0,
      reason:
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}

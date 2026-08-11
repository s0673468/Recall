import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release-capable console logs never interpolate caught exceptions', () {
    final offenders = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      final calls = RegExp(
        r'debugPrint\([\s\S]{0,320}?\);',
        multiLine: true,
      ).allMatches(source);
      for (final call in calls) {
        final text = call.group(0)!;
        if (RegExp(
          r'\$(?:e|error|exception|stackTrace|rollbackError)\b',
        ).hasMatch(text)) {
          offenders.add(file.path);
          break;
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Exception text can contain endpoints, tokens, paths, or content.',
    );
  });

  test('user-facing surfaces never render arbitrary exception text', () {
    final sources = [
      File('lib/app/recall_app.dart'),
      File('lib/features/review/application/review_controller.dart'),
      File('lib/features/settings/presentation/screens/settings_screen.dart'),
    ].map((file) => '${file.path}\n${file.readAsStringSync()}').join('\n');

    for (final forbidden in [
      r"'$error'",
      r"'$e'",
      'error.toString()',
      'e.toString()',
      r"'Could not sign out: $error'",
    ]) {
      expect(
        sources,
        isNot(contains(forbidden)),
        reason: 'User-visible exceptions must map to bounded messages.',
      );
    }
  });
}

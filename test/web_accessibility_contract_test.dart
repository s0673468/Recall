import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the PWA viewport does not disable user zoom', () {
    final index = File('web/index.html').readAsStringSync();
    final viewport = RegExp(
      r'<meta\s+name="viewport"\s+content="([^"]+)"',
    ).firstMatch(index)?.group(1);

    expect(viewport, isNotNull);
    expect(viewport, isNot(contains('user-scalable=no')));
    expect(viewport, isNot(contains('maximum-scale=1')));
  });
}

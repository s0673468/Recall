@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_web/shared_preferences_web.dart';
import 'package:web/web.dart' as web;

import 'package:health_anki_flutter/features/review/data/local_review_write_failure_web.dart';

@JS('Function')
external JSFunction _makeThrower(JSString body);

class _CustomWebBackend extends SharedPreferencesPlugin {}

Object _nativeQuotaThrow() {
  try {
    // No storage is accessed: exercise a real JS-thrown DOMException crossing
    // the Dart bridge in the test-owned browser process.
    _makeThrower(
      'throw new DOMException("invented quota", "QuotaExceededError");'.toJS,
    ).callAsFunction();
  } catch (error) {
    return error;
  }
  throw StateError('Synthetic native throw did not throw.');
}

void main() {
  test('native quota exception from the pinned backend proves rejection', () {
    expect(
      isDefinitelyUncommittedWrite(
        _nativeQuotaThrow(),
        SharedPreferencesPlugin(),
      ),
      isTrue,
    );
  });

  test('a quota-looking Dart error grants no authority', () {
    expect(
      isDefinitelyUncommittedWrite(
        StateError('QuotaExceededError: invented'),
        SharedPreferencesPlugin(),
      ),
      isFalse,
    );
  });

  test('a plain JS object and other DOM exceptions remain unknown', () {
    final backend = SharedPreferencesPlugin();
    expect(
      isDefinitelyUncommittedWrite(
        {'name': 'QuotaExceededError'}.jsify()!,
        backend,
      ),
      isFalse,
    );
    expect(
      isDefinitelyUncommittedWrite(
        web.DOMException('invented', 'SecurityError'),
        backend,
      ),
      isFalse,
    );
  });

  test(
    'custom and subclass backends cannot assert atomic browser semantics',
    () {
      final error = _nativeQuotaThrow();
      expect(
        isDefinitelyUncommittedWrite(
          error,
          InMemorySharedPreferencesStore.empty(),
        ),
        isFalse,
      );
      expect(isDefinitelyUncommittedWrite(error, _CustomWebBackend()), isFalse);
    },
  );
}

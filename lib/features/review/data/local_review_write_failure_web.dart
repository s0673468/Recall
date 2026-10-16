import 'dart:js_interop';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_web/shared_preferences_web.dart';
import 'package:web/web.dart' as web;

bool isDefinitelyUncommittedWrite(
  Object error,
  SharedPreferencesStorePlatform backend,
) {
  try {
    // This pinned backend writes with one atomic Storage.setItem call. A
    // native quota exception proves that replacement was never committed.
    // A custom backend or a quota-looking message grants no retry authority.
    return backend.runtimeType == SharedPreferencesPlugin &&
        error.isA<web.DOMException>() &&
        (error as web.DOMException).name == 'QuotaExceededError';
  } catch (_) {
    return false;
  }
}

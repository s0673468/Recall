// A fake clock for postgrest's automatic retry backoff, so tests that drive a
// 503 or an offline transport keep every retry attempt without sleeping the
// real 1 s + 2 s + 4 s between them.
import 'dart:async';

/// Runs [body] with postgrest's retry backoff timers firing immediately.
///
/// Only the delay that `PostgrestBuilder._executeWithRetry` waits between
/// attempts is shortened. The number and order of retries are unchanged, and
/// every other timer (test timeouts, controller deadlines, request timeouts)
/// keeps its real duration.
Future<T> withInstantRetryBackoff<T>(Future<T> Function() body) {
  return runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration > Duration.zero && _isPostgrestBackoff()) {
          duration = Duration.zero;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

// The backoff is the `Future.delayed` called directly by the retry loop, so
// its first frame outside dart:async is `_executeWithRetry` itself. A timer
// created further down, inside the request it retries, has a different
// caller and keeps its duration.
bool _isPostgrestBackoff() {
  for (final frame in StackTrace.current.toString().split('\n')) {
    if (frame.trim().isEmpty ||
        frame.contains('dart:async') ||
        frame.contains('instant_retry_backoff.dart')) {
      continue;
    }
    return frame.contains('PostgrestBuilder._executeWithRetry') &&
        frame.contains('postgrest_builder.dart');
  }
  return false;
}

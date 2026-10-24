import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web Locks are origin-scoped and exclusive by default. Hold the lock until
/// the whole native read/modify/write completes, including pending-count reads.
Future<T> withPlatformReviewLock<T>(Future<T> Function() action) async {
  late Future<T> result;
  await web.window.navigator.locks
      .request(
        'recall-local-review-store-v1',
        ((web.Lock lock) {
          result = Future<T>.sync(action);
          // Let the browser release its lock on either outcome, while preserving
          // the original Dart exception (not a JS rejection) for the caller.
          return result
              .then<void>((_) {}, onError: (Object _, StackTrace _) {})
              .toJS;
        }).toJS,
      )
      .toDart;
  return result;
}

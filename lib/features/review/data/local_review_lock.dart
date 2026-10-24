import 'local_review_lock_stub.dart'
    if (dart.library.js_interop) 'local_review_lock_web.dart'
    as platform;

final _queues = Expando<_ReviewQueue>();

/// Instances sharing a preferences session share a queue. A reconstructed
/// session must not inherit a dead process's suspended write. On web, the
/// platform lock also spans tabs, preventing stale replacements of ACK receipts.
Future<T> withLocalReviewLock<T>(Object session, Future<T> Function() action) =>
    (_queues[session] ??= _ReviewQueue()).run(action);

class _ReviewQueue {
  Future<void>? _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final run = (_tail ?? Future<void>.value()).then(
      (_) => platform.withPlatformReviewLock(action),
    );
    late final Future<void> tail;
    final completed = run.then<T>(
      (value) {
        if (identical(_tail, tail)) _tail = null;
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_tail, tail)) _tail = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    // Release settled futures so the queue never retains a drained test Zone.
    tail = completed.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _tail = tail;
    return completed;
  }
}

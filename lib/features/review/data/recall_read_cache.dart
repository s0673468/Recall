import 'recall_api.dart';

/// A short-lived, in-memory cache for the read-only aggregates that several
/// surfaces load independently: the long review log, note tags, concept
/// metadata and primers, and the due-date forecast.
///
/// Stats and Read are both mounted at startup and reload on every tab switch,
/// and the done screen's remediation rows read the same data again. This cache
/// lets those callers share one in-flight request and reuse a recent result.
/// It is disposable cache in the README's sense: nothing here is written back,
/// and every entry is rebuildable from Supabase.
///
/// Freshness rules:
///  - an entry is reused for at most [maxAge] after its request started;
///  - review-dependent entries (the review log and due dates) are invalidated
///    as soon as this device delivers or reverts a review ([reviewsChanged]);
///  - an explicit refresh (pull-to-refresh) always issues a new request;
///  - a failed request is never cached;
///  - an account change drops everything ([clear]).
class RecallReadCache {
  RecallReadCache({
    this.maxAge = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static final Expando<RecallReadCache> _byApi = Expando('RecallReadCache');

  /// The cache shared by every surface that reads through [api].
  static RecallReadCache of(RecallApi api) => _byApi[api] ??= RecallReadCache();

  final Duration maxAge;
  final DateTime Function() _clock;
  final Map<String, _CacheEntry> _entries = {};
  int _reviewGeneration = 0;

  /// Returns the cached future for [key] when it is still fresh, otherwise
  /// starts [load] and caches its future. Returning the identical future lets
  /// a FutureBuilder keep its resolved data instead of flashing a spinner.
  Future<T> read<T>(
    String key,
    Future<T> Function() load, {
    bool refresh = false,
    bool reviewDependent = false,
  }) {
    final now = _clock();
    final hit = _entries[key];
    if (!refresh &&
        hit != null &&
        now.difference(hit.startedAt) < maxAge &&
        (!reviewDependent || hit.reviewGeneration == _reviewGeneration)) {
      return hit.future as Future<T>;
    }
    // A loader that throws synchronously still yields a failed future.
    final future = Future<T>.sync(load);
    final entry = _CacheEntry(future, now, _reviewGeneration);
    _entries[key] = entry;
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_entries[key], entry)) _entries.remove(key);
      },
    );
    return future;
  }

  /// This device delivered or reverted a review, so the server's review log
  /// and due dates moved. In-flight review-dependent reads are not reused.
  void reviewsChanged() => _reviewGeneration++;

  /// Forget every entry, e.g. when the signed-in account changes.
  void clear() {
    _entries.clear();
    _reviewGeneration++;
  }
}

class _CacheEntry {
  final Future<Object?> future;
  final DateTime startedAt;
  final int reviewGeneration;

  const _CacheEntry(this.future, this.startedAt, this.reviewGeneration);
}

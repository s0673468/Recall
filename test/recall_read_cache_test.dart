import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/data/recall_read_cache.dart';

void main() {
  late DateTime now;
  late RecallReadCache cache;
  late int loads;

  Future<int> load() async => ++loads;

  setUp(() {
    now = DateTime.utc(2026, 10, 4, 9);
    cache = RecallReadCache(
      maxAge: const Duration(seconds: 60),
      clock: () => now,
    );
    loads = 0;
  });

  test('concurrent callers share one request and the same future', () async {
    final gate = Completer<int>();
    var calls = 0;
    Future<int> slow() {
      calls++;
      return gate.future;
    }

    final first = cache.read('log', slow);
    final second = cache.read('log', slow);
    expect(identical(first, second), isTrue);
    gate.complete(7);
    expect(await second, 7);
    expect(calls, 1);
  });

  test('a fresh entry is reused until it ages out', () async {
    expect(await cache.read('tags', load), 1);
    now = now.add(const Duration(seconds: 59));
    expect(await cache.read('tags', load), 1);
    now = now.add(const Duration(seconds: 1));
    expect(await cache.read('tags', load), 2);
  });

  test('refresh always issues a new request and replaces the entry', () async {
    expect(await cache.read('pages', load), 1);
    expect(await cache.read('pages', load, refresh: true), 2);
    expect(await cache.read('pages', load), 2);
  });

  test('delivered reviews invalidate only review-dependent entries', () async {
    expect(await cache.read('log', load, reviewDependent: true), 1);
    expect(await cache.read('nodes', load), 2);
    cache.reviewsChanged();
    expect(await cache.read('log', load, reviewDependent: true), 3);
    expect(await cache.read('nodes', load), 2);
  });

  test('a review delivered mid-request is not hidden by that request', () async {
    final gate = Completer<int>();
    final inFlight = cache.read(
      'log',
      () => gate.future,
      reviewDependent: true,
    );
    cache.reviewsChanged();
    final next = cache.read('log', load, reviewDependent: true);
    expect(identical(inFlight, next), isFalse);
    gate.complete(0);
    expect(await next, 1);
  });

  test('failures are never cached, including synchronous throws', () async {
    await expectLater(
      cache.read<int>('log', () async => throw StateError('offline')),
      throwsStateError,
    );
    await expectLater(
      cache.read<int>('log', () => throw StateError('sync')),
      throwsStateError,
    );
    expect(await cache.read('log', load), 1);
  });

  test('clear drops every entry', () async {
    expect(await cache.read('a', load), 1);
    expect(await cache.read('b', load), 2);
    cache.clear();
    expect(await cache.read('a', load), 3);
    expect(await cache.read('b', load), 4);
  });
}

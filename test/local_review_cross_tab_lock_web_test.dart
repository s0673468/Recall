@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

import 'package:health_anki_flutter/features/review/data/local_review_lock_web.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('store waits for an origin lock held outside its Dart queue', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    // A separate lock request bypasses the process queue, like another tab.
    final held = web.window.navigator.locks
        .request(
          'recall-local-review-store-v1',
          ((web.Lock lock) {
            entered.complete();
            return release.future.toJS;
          }).toJS,
        )
        .toDart;
    await entered.future;
    var finished = false;
    final write = LocalReviewStore()
        .enqueueReview({'client_id': 'synthetic-browser-review', 'card_id': 1})
        .then((_) => finished = true);
    // Poll the browser's real pending queue, without relying on a timer race.
    var pending = false;
    for (var i = 0; i < 100 && !pending; i++) {
      final snapshot = await web.window.navigator.locks.query().toDart;
      pending = snapshot.pending.toDart.any(
        (lock) => lock.name == 'recall-local-review-store-v1',
      );
      if (!pending) await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(pending, isTrue);
    expect(finished, isFalse);
    release.complete();
    await held;
    await write;
    expect(await LocalReviewStore().outbox(), hasLength(1));
  });

  test(
    'failed browser action releases the lock and preserves its Dart error',
    () async {
      final failure = StateError('synthetic failure');
      await expectLater(
        withPlatformReviewLock<void>(() async => throw failure),
        throwsA(same(failure)),
      );
      expect(await withPlatformReviewLock(() async => 7), 7);
    },
  );
}

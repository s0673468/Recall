// Synthetic regression for a completed migration lock retained across zones.
// Each zone owns its microtask queue, as separate FakeAsync test zones do.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

const _owner = 'invented-zone-lifetime-owner';
const _maxTasksPerDrain = 4000;

class _QueuedMicrotasks {
  final _pending = <void Function()>[];
  final uncaught = <Object>[];

  late final Zone zone = Zone.current.fork(
    specification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, action) {
        _pending.add(() => zone.runGuarded(action));
      },
      handleUncaughtError: (self, parent, zone, error, stackTrace) {
        uncaught.add(error);
      },
    ),
  );

  int get pendingCount => _pending.length;

  // A finite task budget makes a self-scheduling regression fail as an
  // assertion rather than hanging the suite.
  void drain({int limit = _maxTasksPerDrain}) {
    for (var step = 0; step < limit && _pending.isNotEmpty; step++) {
      _pending.removeAt(0)();
    }
  }
}

class _Activation {
  late final LocalReviewStore store;
  bool completed = false;
  Object? error;

  void startIn(_QueuedMicrotasks scheduler) {
    scheduler.zone.run(() {
      // Both the instance outbox tail and its public activation are created
      // in this zone. The observer also belongs to this same zone.
      store = LocalReviewStore();
      store
          .activateOwner(_owner)
          .then<void>(
            (_) {
              completed = true;
            },
            onError: (Object failure, StackTrace stackTrace) {
              error = failure;
              completed = true;
            },
          );
    });
  }
}

void main() {
  test('a new zone can activate after an earlier migration zone is idle', () {
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    final native = InMemorySharedPreferencesStore.withData(<String, Object>{});
    SharedPreferencesStorePlatform.instance = native;
    final firstZone = _QueuedMicrotasks();
    final secondZone = _QueuedMicrotasks();
    final first = _Activation();
    final second = _Activation();

    try {
      first.startIn(firstZone);
      firstZone.drain();
      expect(
        firstZone.pendingCount,
        0,
        reason: 'The first activation exceeded the bounded microtask drain.',
      );
      expect(firstZone.uncaught, isEmpty);
      expect(first.completed, true);
      expect(first.error, isNull);
      expect(first.store.isActiveOwner(_owner), true);

      // Simulate a new test/app preferences singleton while keeping the same
      // native storage. The first zone is now intentionally left idle.
      SharedPreferences.resetStatic();
      second.startIn(secondZone);
      secondZone.drain();

      expect(
        secondZone.pendingCount,
        0,
        reason: 'The second activation exceeded the bounded microtask drain.',
      );
      expect(secondZone.uncaught, isEmpty);
      expect(
        second.completed,
        true,
        reason:
            'A completed earlier migration must not require its old zone '
            'to schedule work for this activation.',
      );
      expect(second.error, isNull);
      expect(second.store.isActiveOwner(_owner), true);
    } finally {
      // Release both zone queues even when the completion assertion fails.
      // This also lets any stranded public futures settle before teardown.
      try {
        for (var round = 0; round < 4; round++) {
          firstZone.drain();
          secondZone.drain();
          if (firstZone.pendingCount == 0 && secondZone.pendingCount == 0) {
            break;
          }
        }
      } finally {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      }
    }
  });
}

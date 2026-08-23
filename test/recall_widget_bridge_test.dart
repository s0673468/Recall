import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/widgets/recall_widget_bridge.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingWidgetStore store;
  late RecallWidgetPublisher publisher;

  setUp(() {
    store = _RecordingWidgetStore();
    publisher = RecallWidgetPublisher(store: store);
  });

  test(
    'does not replace a useful snapshot with cold-start loading zero',
    () async {
      await publisher.publish(
        signedIn: true,
        state: const ReviewState(loading: true),
      );

      expect(store.updates, isEmpty);
      expect(store.clearCount, 0);
    },
  );

  test('publishes only the verified global due count and timestamp', () async {
    final now = DateTime.utc(2026, 7, 13, 12, 30);
    await publisher.publish(
      signedIn: true,
      state: ReviewState(
        loading: false,
        queue: [_card(1, state: 2), _card(2), _card(3, state: 1)],
        index: 1,
        globalDueCount: 17,
        globalDueUpdatedAt: now,
      ),
    );

    expect(store.updates, [RecallWidgetSnapshot(dueCount: 17, updatedAt: now)]);
  });

  test('publishes a fresh timestamp even when count is unchanged', () async {
    final first = DateTime.utc(2026, 7, 13, 12, 30);
    final second = first.add(const Duration(minutes: 5));
    final ready = ReviewState(
      loading: false,
      globalDueCount: 4,
      globalDueUpdatedAt: first,
    );
    await publisher.publish(signedIn: true, state: ready);
    await publisher.publish(
      signedIn: true,
      state: ready.copyWith(globalDueUpdatedAt: second),
    );
    await publisher.publish(signedIn: false, state: ready);
    await publisher.publish(signedIn: false, state: ready);

    expect(store.updates, hasLength(2));
    expect(store.updates.last.updatedAt, second);
    expect(store.clearCount, 1);
  });

  test('retries a sign-out clear after a transient failure', () async {
    store.failNextClear = true;
    const signedOut = ReviewState(loading: false);

    await expectLater(
      publisher.publish(signedIn: false, state: signedOut),
      throwsStateError,
    );
    await publisher.publish(signedIn: false, state: signedOut);

    expect(store.clearCount, 2);
  });

  test(
    'retries an unchanged snapshot after a transient update failure',
    () async {
      store.failNextUpdate = true;
      final now = DateTime.utc(2026, 7, 13, 12, 30);
      final ready = ReviewState(
        loading: false,
        globalDueCount: 9,
        globalDueUpdatedAt: now,
      );

      await expectLater(
        publisher.publish(signedIn: true, state: ready),
        throwsStateError,
      );
      await publisher.publish(signedIn: true, state: ready);

      expect(store.updateAttempts, 2);
      expect(store.updates, [
        RecallWidgetSnapshot(dueCount: 9, updatedAt: now),
      ]);
    },
  );

  test(
    'a new account republishes after the previous update and clear finish',
    () async {
      final now = DateTime.utc(2026, 7, 13, 12, 30);
      final ready = ReviewState(
        loading: false,
        globalDueCount: 9,
        globalDueUpdatedAt: now,
      );
      final firstUpdateStarted = Completer<void>();
      final releaseFirstUpdate = Completer<void>();
      store
        ..nextUpdateStarted = firstUpdateStarted
        ..nextUpdateGate = releaseFirstUpdate;

      final accountA = publisher.publish(
        signedIn: true,
        ownerId: 'account-a',
        state: ready,
      );
      await firstUpdateStarted.future;
      final signOut = publisher.publish(signedIn: false, state: ready);
      final accountB = publisher.publish(
        signedIn: true,
        ownerId: 'account-b',
        state: ready,
      );

      releaseFirstUpdate.complete();
      await Future.wait([accountA, signOut, accountB]);

      expect(store.updates, [
        RecallWidgetSnapshot(dueCount: 9, updatedAt: now),
        RecallWidgetSnapshot(dueCount: 9, updatedAt: now),
      ]);
      expect(store.clearCount, 1);
      expect(store.operations, ['update:9', 'clear', 'update:9']);
    },
  );

  test('a direct account replacement starts a new dedupe session', () async {
    final now = DateTime.utc(2026, 7, 13, 12, 30);
    final ready = ReviewState(
      loading: false,
      globalDueCount: 4,
      globalDueUpdatedAt: now,
    );

    await publisher.publish(signedIn: true, ownerId: 'account-a', state: ready);
    await publisher.publish(signedIn: true, ownerId: 'account-b', state: ready);

    expect(store.updateAttempts, 2);
  });

  test('the latest rapid sign-out queues a trailing native clear', () async {
    final now = DateTime.utc(2026, 7, 13, 12, 30);
    final ready = ReviewState(
      loading: false,
      globalDueCount: 6,
      globalDueUpdatedAt: now,
    );
    final firstUpdateStarted = Completer<void>();
    final releaseFirstUpdate = Completer<void>();
    store
      ..nextUpdateStarted = firstUpdateStarted
      ..nextUpdateGate = releaseFirstUpdate;

    final accountA = publisher.publish(
      signedIn: true,
      ownerId: 'account-a',
      state: ready,
    );
    await firstUpdateStarted.future;
    final accountASignOut = publisher.publish(signedIn: false, state: ready);
    final accountB = publisher.publish(
      signedIn: true,
      ownerId: 'account-b',
      state: ready,
    );
    final accountBSignOut = publisher.publish(signedIn: false, state: ready);

    releaseFirstUpdate.complete();
    await Future.wait([accountA, accountASignOut, accountB, accountBSignOut]);

    expect(store.operations, ['update:6', 'clear', 'update:6', 'clear']);
    expect(store.clearCount, 2);
  });

  test('native channel receives only count and timestamp', () async {
    final now = DateTime.utc(2026, 7, 13, 12, 30);
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelRecallWidgetStore.channel, (
          call,
        ) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannelRecallWidgetStore.channel,
            null,
          );
    });

    await const MethodChannelRecallWidgetStore().update(
      RecallWidgetSnapshot(dueCount: 7, updatedAt: now),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'update');
    expect(calls.single.arguments, {
      'dueCount': 7,
      'updatedAtEpochMs': now.millisecondsSinceEpoch,
    });
  });

  test('Android channel receives the same aggregate-only snapshot', () async {
    final now = DateTime.utc(2026, 7, 13, 12, 30);
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelRecallWidgetStore.channel, (
          call,
        ) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannelRecallWidgetStore.channel,
            null,
          );
    });

    await const MethodChannelRecallWidgetStore().update(
      RecallWidgetSnapshot(dueCount: 7, updatedAt: now),
    );

    expect(calls, hasLength(1));
    expect(calls.single.arguments, {
      'dueCount': 7,
      'updatedAtEpochMs': now.millisecondsSinceEpoch,
    });
  });
}

ReviewCard _card(int id, {int state = 0}) => ReviewCard(
  id: id,
  guid: 'g$id',
  deckId: 1,
  front: 'private front $id',
  back: 'private back $id',
  hasLatex: false,
  stability: null,
  difficulty: null,
  due: null,
  state: state,
  reps: 0,
  lapses: 0,
  lastReview: null,
);

class _RecordingWidgetStore implements RecallWidgetStore {
  final updates = <RecallWidgetSnapshot>[];
  final operations = <String>[];
  int clearCount = 0;
  int updateAttempts = 0;
  bool failNextClear = false;
  bool failNextUpdate = false;
  Completer<void>? nextUpdateStarted;
  Completer<void>? nextUpdateGate;

  @override
  Future<void> clear() async {
    clearCount++;
    operations.add('clear');
    if (failNextClear) {
      failNextClear = false;
      throw StateError('transient App Group failure');
    }
  }

  @override
  Future<void> update(RecallWidgetSnapshot snapshot) async {
    updateAttempts++;
    nextUpdateStarted?.complete();
    nextUpdateStarted = null;
    final gate = nextUpdateGate;
    nextUpdateGate = null;
    await gate?.future;
    if (failNextUpdate) {
      failNextUpdate = false;
      throw StateError('transient App Group failure');
    }
    updates.add(snapshot);
    operations.add('update:${snapshot.dueCount}');
  }
}

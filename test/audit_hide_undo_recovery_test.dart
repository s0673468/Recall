import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

// Only invented cards, session identities and an in-memory native backend.
class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.withData({});

  bool refuseWithdrawal = false;
  bool refuseDrain = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (refuseDrain && key.contains('flag_outbox_v1') && value == '[]') {
      return false;
    }
    if (refuseWithdrawal &&
        key.contains('flag_outbox_v1') &&
        value is String &&
        (jsonDecode(value) as List).any((e) => e['op'] == 'dismiss')) {
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _Api extends FakeRecallApi {
  _Api() : super([testCard(id: 1), testCard(id: 2), testCard(id: 3)]);

  final hiddenByOwner = <String, Set<int>>{};

  @override
  Future<Set<int>> fetchHiddenCardIds() async => {
    ...?hiddenByOwner[currentUser?.id],
  };
}

User _user(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-10-17T00:00:00Z',
);

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 1000 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  setUp(() {
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    native = _Native();
    SharedPreferencesStorePlatform.instance = native;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    });
  });

  Future<(ReviewController, _Api, LocalReviewStore)> session() async {
    final api = _Api()..user = _user('synthetic-owner-a');
    final store = LocalReviewStore();
    await store.activateOwner(api.currentUser!.id);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      reviewSendTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(controller.dispose);
    await controller.load();
    return (controller, api, store);
  }

  test(
    'refused withdrawal preserves the pending hide across restart',
    () async {
      final (controller, api, store) = await session();
      final sending = Completer<void>();
      var started = false;
      api.beforeApplyFlag = () {
        started = true;
        return sending.future;
      };
      addTearDown(() async {
        if (!sending.isCompleted) sending.complete();
        await controller.syncPending();
      });
      await controller.hideCurrent('delete');
      await _until(() => started);
      final original = (await store.flagOutbox()).single;

      native.refuseWithdrawal = true;
      await controller.undo();

      expect(controller.state.current?.id, 2);
      // Model process death by reading persisted truth with a fresh Store.
      final restarted = LocalReviewStore();
      await restarted.activateOwner(api.currentUser!.id);
      expect(await restarted.flagOutbox(), [original]);

      native.refuseWithdrawal = false;
      await controller.undo();
      expect(controller.state.current?.id, 1);
      expect((await restarted.flagOutbox()).single['op'], 'dismiss');
      sending.complete();
      await controller.syncPending();
      expect(await restarted.flagOutbox(), isEmpty);
      expect(api.dismissedFlags, [original['client_id']]);
    },
  );

  test('a process restart during a withdrawal can replay its durable intent',
      () async {
    final (controller, api, store) = await session();
    await controller.hideCurrent('delete');
    await controller.syncPending();
    final entered = Completer<void>();
    final release = Completer<void>();
    api.beforeDismissFlag = () async {
      entered.complete();
      await release.future;
    };
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final undo = controller.undo();
    await entered.future;

    // A fresh process sees the withdrawal even before the network replies.
    final restarted = LocalReviewStore();
    await restarted.activateOwner(api.currentUser!.id);
    expect((await restarted.flagOutbox()).single['op'], 'dismiss');
    final replay = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: restarted,
    );
    addTearDown(replay.dispose);
    api.beforeDismissFlag = null;
    await replay.syncPending();
    expect(await restarted.flagOutbox(), isEmpty);
    release.complete();
    await undo;
    expect(await store.flagOutbox(), isEmpty);
    expect(api.dismissedFlags.toSet(), {api.flagged.single['client_id']});
  });

  test('refused acknowledgement after withdrawal keeps Undo usable', () async {
    final (controller, api, store) = await session();
    await controller.hideCurrent('delete');
    await controller.syncPending();
    native.refuseDrain = true;

    await controller.undo();

    expect(controller.state.current?.id, 1);
    expect(controller.undoInFlight, isFalse);
    expect((await store.flagOutbox()).single['op'], 'dismiss');
    native.refuseDrain = false;
    await controller.syncPending();
    expect(await store.flagOutbox(), isEmpty);
    expect(api.dismissedFlags.toSet(), {api.flagged.single['client_id']});
  });

  for (final failWithdrawal in [false, true]) {
    test('late ${failWithdrawal ? 'failed' : 'successful'} withdrawal stays '
        'in its original account', () async {
      final (controller, api, store) = await session();
      final ownerA = store.activeOwnerScope;
      await controller.hideCurrent('delete');
      await controller.syncPending();
      final originalId = api.flagged.single['client_id'];
      final withdrawing = Completer<void>();
      final release = Completer<void>();
      api.beforeDismissFlag = () async {
        withdrawing.complete();
        await release.future;
        if (failWithdrawal) throw StateError('synthetic lost connection');
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final undo = controller.undo();
      await withdrawing.future;

      api.user = _user('synthetic-owner-b');
      await store.activateOwner(api.currentUser!.id);
      api.hiddenByOwner[api.currentUser!.id] = {1};
      await controller.load();
      final ownerBQueue = controller.state.queue;
      expect(await store.hiddenCardIds(), {1});
      release.complete();
      await undo;

      expect(await store.flagOutbox(), isEmpty);
      expect(await store.hiddenCardIds(), {1});
      expect(controller.state.queue, same(ownerBQueue));
      await controller.keepGoing();
      expect(api.lastAheadExcludedCardIds, {1});
      final queuedA = await store.flagOutbox(ownerScope: ownerA);
      if (failWithdrawal) {
        expect(queuedA.single, {
          'op': 'dismiss',
          'card_id': 1,
          'client_id': originalId,
        });
      } else {
        expect(queuedA, isEmpty);
      }
    });
  }
}

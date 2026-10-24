// Synthetic cards and in-memory native storage only.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.withData({});

  int failedReads = 0;
  bool throwWithdrawal = false;
  bool commitWithdrawal = false;

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) {
    if (failedReads > 0) {
      failedReads--;
      throw StateError('synthetic transient native read failure');
    }
    return super.getAllWithParameters(parameters);
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (throwWithdrawal &&
        key.contains('flag_outbox_v1') &&
        value is String &&
        (jsonDecode(value) as List).any((e) => e['op'] == 'dismiss')) {
      if (commitWithdrawal) await super.setValue(type, key, value);
      throw StateError('synthetic lost native reply');
    }
    return super.setValue(type, key, value);
  }
}

class _Api extends FakeRecallApi {
  _Api() : super([testCard(id: 1), testCard(id: 2)]);

  Completer<void>? likedReadGate;
  final likedReadStarted = Completer<void>();
  bool failLikedRead = false;

  @override
  Future<List<Map<String, dynamic>>> fetchLikedFlags() async {
    if (!likedReadStarted.isCompleted) likedReadStarted.complete();
    if (failLikedRead) throw StateError('synthetic offline likes');
    final rows = await super.fetchLikedFlags();
    await likedReadGate?.future;
    return rows;
  }

  List<Map<String, dynamic>> get openLikes => [
    for (final row in flagged)
      if (row['reason'] == 'like' && !dismissedFlags.contains(row['client_id']))
        row,
  ];
}

const _serverLike = {
  'card_id': 1,
  'reason': 'like',
  'client_id': 'synthetic-existing-like',
};

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

  ReviewController build(_Api api, LocalReviewStore store) {
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  for (final failure in ['read', 'uncommitted write']) {
    test(
      'unlike rejects $failure instead of confirming the queued like',
      () async {
        final api = _Api()..failApplyFlag = true;
        final store = LocalReviewStore();
        final controller = build(api, store);
        await controller.load();
        await controller.toggleLike();
        await controller.syncPending();
        final original = (await store.flagOutbox()).single;

        if (failure == 'read') {
          native.failedReads = 1;
        } else {
          native.throwWithdrawal = true;
        }
        await expectLater(
          controller.toggleLike(),
          throwsA(isA<StudyActionNotSavedException>()),
        );
        expect(controller.currentLiked, isTrue);
        expect(controller.flagNotice, isNot('Like removed'));
        expect(await store.flagOutbox(), [original]);
        expect(api.dismissedFlags, isEmpty);

        // Even the eager cache from a failed replacement cannot turn a later
        // insert ACK into an unsolicited withdrawal.
        native.throwWithdrawal = false;
        api.failApplyFlag = false;
        await controller.syncPending();
        expect(await store.flagOutbox(), isEmpty);
        expect(api.openLikes, hasLength(1));
        expect(api.dismissedFlags, isEmpty);

        await controller.toggleLike();
        await controller.syncPending();
        expect(api.openLikes, isEmpty);
        expect(controller.currentLiked, isFalse);
      },
    );
  }

  test(
    'unlike with a lost reply succeeds only for a durable dismissal',
    () async {
      final api = _Api()..failApplyFlag = true;
      final store = LocalReviewStore();
      final controller = build(api, store);
      await controller.load();
      await controller.toggleLike();
      await controller.syncPending();
      final original = (await store.flagOutbox()).single;
      native
        ..throwWithdrawal = true
        ..commitWithdrawal = true;
      api.failDismissFlag = true;

      await controller.toggleLike();
      await controller.syncPending();
      expect(controller.currentLiked, isFalse);
      expect(controller.flagNotice, 'Like removed');
      final durable = (await LocalReviewStore().flagOutbox()).single;
      expect(durable['op'], 'dismiss');
      expect(durable['like_client_ids'], [original['client_id']]);
      native.throwWithdrawal = false;
      api.failApplyFlag = false;
      api.failDismissFlag = false;
      await controller.syncPending();
      expect(api.openLikes, isEmpty);
      expect(await store.flagOutbox(), isEmpty);
    },
  );

  test(
    'withdrawal recovery checks every target and preserves the original',
    () async {
      final store = LocalReviewStore();
      final original = {
        ..._serverLike,
        'op': 'dismiss',
        'like_client_ids': ['synthetic-existing-like'],
      };
      await store.enqueueFlag(original);
      final replacement = {
        ...original,
        'like_client_ids': ['synthetic-existing-like', 'synthetic-other-like'],
      };
      expect(await store.settleUnknownFlagWithdrawal(replacement), isNull);
      expect(await store.flagOutbox(), [original]);
      // A mismatch cannot tombstone the shared ID or prevent the original ACK.
      expect(await store.removeAcknowledgedFlags([original]), 0);
      expect(await LocalReviewStore().flagOutbox(), isEmpty);

      await store.enqueueFlag(replacement);
      expect(await store.settleUnknownFlagWithdrawal(replacement), 1);
    },
  );

  for (final unlikeBeforeRead in [false, true]) {
    test(
      'early tap reuses server like; early unlike=$unlikeBeforeRead',
      () async {
        final gate = Completer<void>();
        final api = _Api()
          ..flagged.add(Map<String, dynamic>.from(_serverLike))
          ..likedReadGate = gate;
        final store = LocalReviewStore();
        final controller = build(api, store);
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await controller.syncPending();
        });
        await controller.load();
        await api.likedReadStarted.future;
        expect(controller.state.current?.id, 1);
        expect(controller.currentLiked, isFalse);

        await controller.toggleLike();
        if (unlikeBeforeRead) await controller.toggleLike();
        gate.complete();
        await controller.syncPending();
        expect(api.flagged, [_serverLike]);
        expect(api.openLikes, hasLength(unlikeBeforeRead ? 0 : 1));
        expect(controller.currentLiked, !unlikeBeforeRead);

        if (!unlikeBeforeRead) {
          await controller.toggleLike();
          await controller.syncPending();
        }
        expect(api.dismissedFlags, contains(_serverLike['client_id']));
        expect(api.openLikes, isEmpty);
        expect(await store.flagOutbox(), isEmpty);
        await controller.refresh();
        expect(controller.currentLiked, isFalse);
        expect(controller.state.current?.id, 1);
        expect(api.applied, isEmpty);
      },
    );
  }

  for (final unlikeOffline in [false, true]) {
    test(
      'offline fresh install reconciles existing like; unlike=$unlikeOffline',
      () async {
        final api = _Api()
          ..flagged.add(Map<String, dynamic>.from(_serverLike))
          ..failLikedRead = true
          ..failApplyFlag = true
          ..failDismissFlag = true;
        final store = LocalReviewStore();
        final controller = build(api, store);
        await controller.load();
        await controller.toggleLike();
        await controller.syncPending();
        if (unlikeOffline) {
          await controller.toggleLike();
          await controller.syncPending();
        }

        // Outbox and cache must survive an app restart before reconnecting.
        final restarted = build(api, LocalReviewStore());
        await restarted.load();
        expect(restarted.currentLiked, !unlikeOffline);
        api
          ..failLikedRead = false
          ..failApplyFlag = false
          ..failDismissFlag = false;
        await restarted.syncPending();
        expect(api.flagged, [_serverLike]);
        expect(api.openLikes, hasLength(unlikeOffline ? 0 : 1));
        if (!unlikeOffline) {
          await restarted.toggleLike();
          await restarted.syncPending();
        }
        expect(api.openLikes, isEmpty);
        expect(await store.flagOutbox(), isEmpty);
      },
    );
  }

  test(
    'unknown server likes defer insertion even if flag writes work',
    () async {
      final api = _Api()
        ..flagged.add(Map<String, dynamic>.from(_serverLike))
        ..failLikedRead = true;
      final store = LocalReviewStore();
      final controller = build(api, store);
      await controller.load();
      await controller.toggleLike();
      await controller.syncPending();
      expect(api.flagged, [_serverLike]);
      expect(await store.flagOutbox(), hasLength(1));
      expect(controller.currentLiked, isTrue);
      api.failLikedRead = false;
      await controller.syncPending();
      expect(api.flagged, [_serverLike]);
      expect(await store.flagOutbox(), isEmpty);
    },
  );

  test(
    'unknown server likes keep unlike queued until every identity is known',
    () async {
      final api = _Api()..flagged.add(Map<String, dynamic>.from(_serverLike));
      final store = LocalReviewStore();
      await store.replaceLikedFlags([Map<String, dynamic>.from(_serverLike)]);
      api.failLikedRead = true;
      final controller = build(api, store);
      await controller.load();
      await controller.toggleLike();
      await controller.syncPending();
      expect(controller.currentLiked, isFalse);
      expect(api.dismissedFlags, isEmpty);
      expect((await store.flagOutbox()).single['op'], 'dismiss');

      api.flagged.add({..._serverLike, 'client_id': 'synthetic-another-like'});
      api.failLikedRead = false;
      await controller.syncPending();
      expect(api.openLikes, isEmpty);
      expect(
        api.dismissedFlags,
        containsAll(['synthetic-existing-like', 'synthetic-another-like']),
      );
      expect(await store.flagOutbox(), isEmpty);
    },
  );
}

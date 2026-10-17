// Invented events and cards only; exercise the real eager preferences cache.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_preferences.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.withData({});

  bool refuseWithdrawal = false;
  bool throwWithdrawal = false;
  bool knownRefusal = false;
  bool failReload = false;
  bool refuseDrain = false;

  @override
  Future<Map<String, Object>> getAll() {
    if (failReload) throw StateError('synthetic failed cache reload');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (refuseDrain && key.contains('flag_outbox_v1') && value == '[]') {
      return false;
    }
    if (key.contains('flag_outbox_v1') &&
        value is String &&
        (jsonDecode(value) as List).any((e) => e['op'] == 'dismiss')) {
      if (throwWithdrawal) throw StateError('synthetic unknown commit');
      if (knownRefusal) {
        failReload = true;
        throw const LocalPreferenceWriteNotCommitted();
      }
      if (refuseWithdrawal) return false;
    }
    return super.setValue(type, key, value);
  }
}

const _hide = <String, dynamic>{
  'client_id': 'invented-hide',
  'card_id': 1,
  'reason': 'delete',
};
const _withdrawal = <String, dynamic>{
  'client_id': 'invented-hide',
  'card_id': 1,
  'op': 'dismiss',
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

  test(
    'refused Undo lets the running hide drain without retrying Undo',
    () async {
      final api = FakeRecallApi([testCard(id: 1), testCard(id: 2)]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        reviewSendTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(controller.dispose);
      await controller.load();
      final entered = Completer<void>();
      final release = Completer<void>();
      api.beforeApplyFlag = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await controller.syncPending();
      });
      await controller.hideCurrent('delete');
      await entered.future;
      final original = (await store.flagOutbox()).single;

      native.refuseWithdrawal = true;
      await controller.undo();
      expect(controller.state.current?.id, 2);
      expect(await store.flagOutbox(), [original]);

      release.complete();
      await controller.syncPending();
      expect(await store.flagOutbox(), isEmpty);
      expect(await LocalReviewStore().flagOutbox(), isEmpty);
      await controller.syncPending();
      expect(api.flagged, [original]);
      expect(api.dismissedFlags, isEmpty);
      await controller.signOut();
      expect(api.signedOut, isTrue);
    },
  );

  test('hide ACK excludes only the refused withdrawal payload', () async {
    final store = LocalReviewStore();
    await store.enqueueFlag(_hide);
    native.refuseWithdrawal = true;
    await expectLater(
      store.enqueueFlag(_withdrawal),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    const other = {
      'client_id': 'invented-other',
      'card_id': 2,
      'reason': 'wrong',
    };
    // Another producer's eager same-key cache entry has no known outcome in
    // this Store. It must survive the ACK rather than being reloaded away.
    final writer = await SharedPreferences.getInstance();
    expect(
      await writer.setString(
        'flag_outbox_v1',
        jsonEncode([_withdrawal, other]),
      ),
      isFalse,
    );
    native.refuseWithdrawal = false;

    expect(await store.removeAcknowledgedFlags([_hide]), 1);
    expect(await store.flagOutbox(), [other]);
    expect(await LocalReviewStore().flagOutbox(), [other]);
    expect(await store.removeAcknowledgedFlags([other]), 0);
  });

  test(
    'definite withdrawal refusal still drains when cache reload fails',
    () async {
      final store = LocalReviewStore();
      await store.enqueueFlag(_hide);
      native.knownRefusal = true;
      await expectLater(
        store.enqueueFlag(_withdrawal),
        throwsA(isA<LocalPreferenceWriteNotCommitted>()),
      );
      expect(await store.flagOutbox(), [_hide]);

      expect(await store.removeAcknowledgedFlags([_hide]), 0);
      expect(await store.flagOutbox(), isEmpty);
    },
  );

  test(
    'refused hide ACK can retry without resurrecting the withdrawal',
    () async {
      final store = LocalReviewStore();
      await store.enqueueFlag(_hide);
      native.refuseWithdrawal = true;
      await expectLater(
        store.enqueueFlag(_withdrawal),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      native.refuseDrain = true;
      await expectLater(
        store.removeAcknowledgedFlags([_hide]),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(await store.flagOutbox(), [_hide]);

      native.refuseDrain = false;
      expect(await store.removeAcknowledgedFlags([_hide]), 0);
      expect(await store.flagOutbox(), isEmpty);
    },
  );

  for (final peerCommit in [false, true]) {
    test(
      'committed withdrawal survives the old hide ACK: peer=$peerCommit',
      () async {
        final store = LocalReviewStore();
        await store.enqueueFlag(_hide);
        native.refuseWithdrawal = true;
        await expectLater(
          store.enqueueFlag(_withdrawal),
          throwsA(isA<LocalOutboxWriteException>()),
        );
        native.refuseWithdrawal = false;
        await (peerCommit ? LocalReviewStore() : store).enqueueFlag(
          _withdrawal,
        );

        expect(await store.removeAcknowledgedFlags([_hide]), 1);
        expect(await store.flagOutbox(), [_withdrawal]);
        expect(await store.removeAcknowledgedFlags([_withdrawal]), 0);
        expect(await store.flagOutbox(), isEmpty);
      },
    );
  }

  test(
    'unknown withdrawal commit keeps the conflicting cache protected',
    () async {
      final store = LocalReviewStore();
      await store.enqueueFlag(_hide);
      native.throwWithdrawal = true;
      await expectLater(store.enqueueFlag(_withdrawal), throwsStateError);
      native.throwWithdrawal = false;

      expect(await store.removeAcknowledgedFlags([_hide]), 2);
      expect(await store.flagOutbox(), [_hide]);
      // A later explicit retry can still replace the hide and drain normally.
      await store.enqueueFlag(_withdrawal);
      expect(await store.removeAcknowledgedFlags([_withdrawal]), 0);
    },
  );

  test('an unknown retry supersedes an earlier definite refusal', () async {
    final store = LocalReviewStore();
    await store.enqueueFlag(_hide);
    native.refuseWithdrawal = true;
    await expectLater(
      store.enqueueFlag(_withdrawal),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    native.refuseWithdrawal = false;
    native.throwWithdrawal = true;
    await expectLater(store.enqueueFlag(_withdrawal), throwsStateError);
    native.throwWithdrawal = false;

    expect(await store.removeAcknowledgedFlags([_hide]), 2);
    expect(await store.flagOutbox(), [_hide]);
    await store.enqueueFlag(_withdrawal);
    expect(await store.removeAcknowledgedFlags([_withdrawal]), 0);
  });
}

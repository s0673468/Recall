// Synthetic owner-migration failures against the real cached preferences API.
// The platform store retains only accepted writes across an app restart.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

enum _Failure { refused, thrown }

class _DurableNative extends InMemorySharedPreferencesStore {
  _DurableNative(super.values) : super.withData();

  String? failKeyPart;
  _Failure failure = _Failure.refused;
  final failedKeys = <String>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failKeyPart != null && key.contains(failKeyPart!)) {
      failedKeys.add(key);
      if (failure == _Failure.thrown) {
        throw StateError('synthetic native write failure: $key');
      }
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

_DurableNative _install(Map<String, Object> durable) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _DurableNative(durable);
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

// Drop the Dart singleton and store, leaving the platform's durable map intact.
LocalReviewStore _restart() {
  SharedPreferences.resetStatic();
  return LocalReviewStore();
}

String _scope(String owner) =>
    sha256.convert(utf8.encode(owner)).toString().substring(0, 24);

String _scoped(String base, String owner) => '$base:owner:${_scope(owner)}';
String _native(String key) => 'flutter.$key';
String _outbox(String id) => jsonEncode([
  {'client_id': id, 'card_id': 42, 'rating': 3},
]);
String _flags(String id) => jsonEncode([
  {'client_id': id, 'card_id': 42, 'reason': 'synthetic bad card'},
]);

Matcher _failureMatcher(_Failure failure) => failure == _Failure.refused
    ? isA<LocalOutboxWriteException>()
    : isA<StateError>();

Future<List<Object?>> _ids(
  LocalReviewStore store, {
  bool flags = false,
}) async => (flags ? await store.flagOutbox() : await store.outbox())
    .map((entry) => entry['client_id'])
    .toList();

void main() {
  const first = 'invented-first-owner';
  const second = 'invented-second-owner';
  const outboxBase = 'recall_outbox_v1';
  const flagOutboxBase = 'flag_outbox_v1';
  const claimKey = 'recall_local_state_owner_v1';
  const migrationBase = 'recall_local_state_migrated_v1';

  for (final failure in _Failure.values) {
    for (final base in [outboxBase, flagOutboxBase]) {
      test('failed $base copy survives restart: $failure', () async {
        final isFlag = base == flagOutboxBase;
        final legacy = isFlag ? _flags('legacy-only') : _outbox('legacy-only');
        final native = _install({_native(base): legacy});
        final store = LocalReviewStore();
        final destination = _scoped(base, first);
        final migration = '$migrationBase:${_scope(first)}';
        native
          ..failKeyPart = destination
          ..failure = failure;

        await expectLater(
          store.activateOwner(first),
          throwsA(_failureMatcher(failure)),
        );
        expect(store.activeOwnerScope, isNull);
        expect(native.failedKeys, contains(_native(destination)));
        expect(
          (await native.getAll()).containsKey(_native(destination)),
          isFalse,
        );
        // The real SharedPreferences cache accepted the failed value.
        expect(
          (await SharedPreferences.getInstance()).getString(destination),
          legacy,
        );

        native.failKeyPart = null;
        await store.activateOwner(first);

        // Check the public read after restart before inspecting native keys:
        // main loses this pending action despite a successful retry.
        final restarted = _restart();
        await restarted.activateOwner(first);
        expect(await _ids(restarted, flags: isFlag), ['legacy-only']);
        await restarted.activateOwner(second);
        expect(await _ids(restarted, flags: isFlag), isEmpty);

        final durable = await native.getAll();
        expect(durable[_native(claimKey)], _scope(first));
        expect(durable[_native(destination)], legacy);
        expect(durable[_native(migration)], isTrue);
        expect(durable[_native(base)], legacy); // Recovery copy retained.
      });
    }

    test(
      'failed claim retries durably before another owner: $failure',
      () async {
        final legacy = _outbox('legacy-only');
        final native = _install({_native(outboxBase): legacy});
        final store = LocalReviewStore();
        native
          ..failKeyPart = claimKey
          ..failure = failure;

        await expectLater(
          store.activateOwner(first),
          throwsA(_failureMatcher(failure)),
        );
        expect(store.activeOwnerScope, isNull);
        expect((await native.getAll()).containsKey(_native(claimKey)), isFalse);
        expect(
          (await SharedPreferences.getInstance()).getString(claimKey),
          _scope(first),
        );

        native.failKeyPart = null;
        await store.activateOwner(first);
        expect(await _ids(store), ['legacy-only']);

        final restarted = _restart();
        await restarted.activateOwner(second);
        expect(await _ids(restarted), isEmpty);
        expect((await native.getAll())[_native(claimKey)], _scope(first));
        await restarted.activateOwner(first);
        expect(await _ids(restarted), ['legacy-only']);
      },
    );

    test(
      'failed migration flag cannot resurrect cleared review: $failure',
      () async {
        final legacy = _outbox('already-delivered');
        final native = _install({_native(outboxBase): legacy});
        final store = LocalReviewStore();
        final migration = '$migrationBase:${_scope(first)}';
        native
          ..failKeyPart = migration
          ..failure = failure;

        await expectLater(
          store.activateOwner(first),
          throwsA(_failureMatcher(failure)),
        );
        expect(store.activeOwnerScope, isNull);
        expect(
          (await native.getAll()).containsKey(_native(migration)),
          isFalse,
        );
        expect(
          (await SharedPreferences.getInstance()).getBool(migration),
          isTrue,
        );
        expect(
          (await native.getAll())[_native(_scoped(outboxBase, first))],
          legacy,
        );

        native.failKeyPart = null;
        await store.activateOwner(first);
        expect((await native.getAll())[_native(migration)], isTrue);
        expect(await store.removeFirst(1), 0);
        expect(await _ids(store), isEmpty);
        await store
            .clear(); // Remove the empty scoped key; keep legacy recovery.

        final restarted = _restart();
        await restarted.activateOwner(first);
        expect(await _ids(restarted), isEmpty);
        expect((await native.getAll())[_native(outboxBase)], legacy);
      },
    );
  }

  test(
    'migration preserves durable scoped progress and legacy recovery',
    () async {
      final legacy = _outbox('legacy-only');
      final existing = _outbox('scoped-progress');
      final native = _install({
        _native(outboxBase): legacy,
        _native(_scoped(outboxBase, first)): existing,
        _native('recall_catch_up_v1'): 'legacy-choice',
        _native(_scoped('recall_catch_up_v1', first)): 'scoped-choice',
      });
      final store = LocalReviewStore();

      await store.activateOwner(first);
      expect(await _ids(store), ['scoped-progress']);
      final durable = await native.getAll();
      expect(durable[_native(_scoped(outboxBase, first))], existing);
      expect(
        durable[_native(_scoped('recall_catch_up_v1', first))],
        'scoped-choice',
      );
      expect(durable[_native(outboxBase)], legacy);
      expect(durable[_native('recall_catch_up_v1')], 'legacy-choice');
      expect(durable[_native('$migrationBase:${_scope(first)}')], isTrue);

      final restarted = _restart();
      await restarted.activateOwner(second);
      expect(await _ids(restarted), isEmpty);
      await restarted.activateOwner(first);
      expect(await _ids(restarted), ['scoped-progress']);
    },
  );
}

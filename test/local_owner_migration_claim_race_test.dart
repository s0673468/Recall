// Synthetic concurrent owner migrations using the real cached preferences API.
// The first native claim is held after SharedPreferences has updated its cache.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

const _first = 'invented-first-owner';
const _second = 'invented-second-owner';
const _outboxKey = 'recall_outbox_v1';
const _claimKey = 'recall_local_state_owner_v1';
const _migrationKey = 'recall_local_state_migrated_v1';
const _limit = Duration(seconds: 5);

String _scope(String owner) =>
    sha256.convert(utf8.encode(owner)).toString().substring(0, 24);
String _nativeKey(String key) => 'flutter.$key';
String _scopedOutbox(String owner) => '$_outboxKey:owner:${_scope(owner)}';

enum _ClaimFailure { refused, thrown }

class _HeldClaimNative extends InMemorySharedPreferencesStore {
  _HeldClaimNative(super.values) : super.withData();

  final firstClaimStarted = Completer<void>();
  final releaseFirstClaim = Completer<void>();
  final claimAttempts = <String>[];
  _ClaimFailure? firstClaimFailure;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _nativeKey(_claimKey)) {
      claimAttempts.add(value as String);
      if (claimAttempts.length == 1) {
        firstClaimStarted.complete();
        await releaseFirstClaim.future;
        switch (firstClaimFailure) {
          case _ClaimFailure.refused:
            return false;
          case _ClaimFailure.thrown:
            throw StateError('synthetic first native claim failure');
          case null:
            break;
        }
      }
    }
    return super.setValue(valueType, key, value);
  }

  void release() {
    if (!releaseFirstClaim.isCompleted) releaseFirstClaim.complete();
  }
}

_HeldClaimNative _install() {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _HeldClaimNative({
    _nativeKey(_outboxKey): jsonEncode([
      {'client_id': 'invented-legacy-review', 'card_id': 42, 'rating': 3},
    ]),
  });
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    native.release();
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Future<List<Object?>> _ids(LocalReviewStore store) async =>
    (await store.outbox()).map((entry) => entry['client_id']).toList();

// Attach an error handler immediately, while assertions still await the
// original future. A failed assertion must not strand an unobserved activation.
Future<void> _settled(Future<void> operation) =>
    operation.then<void>((_) {}, onError: (Object _) {});

void main() {
  test(
    'two stores give legacy reviews only to the durable first claimant',
    () async {
      final native = _install();
      final firstStore = LocalReviewStore();
      final secondStore = LocalReviewStore();
      final firstActivation = firstStore.activateOwner(_first);
      final firstSettled = _settled(firstActivation);
      Future<void>? secondActivation;
      Future<void>? secondSettled;

      try {
        await native.firstClaimStarted.future.timeout(_limit);
        // The public setter has changed the shared Dart cache, but no native
        // claim has been accepted yet.
        expect(
          (await SharedPreferences.getInstance()).getString(_claimKey),
          _scope(_first),
        );
        expect(
          (await native.getAll()).containsKey(_nativeKey(_claimKey)),
          false,
        );

        secondActivation = secondStore.activateOwner(_second);
        secondSettled = _settled(secondActivation);
        // activateOwner has queued its public Future on the second store. Yield
        // all runnable microtasks before opening A's gate, using an event fence.
        await Future<void>(() {});
        native.release();
        await Future.wait([firstActivation, secondActivation]).timeout(_limit);

        expect(await _ids(firstStore), ['invented-legacy-review']);
        expect(await _ids(secondStore), isEmpty);
        expect(firstStore.isActiveOwner(_first), true);
        expect(secondStore.isActiveOwner(_second), true);
        final durable = await native.getAll();
        expect(durable[_nativeKey(_claimKey)], _scope(_first));
        expect(durable[_nativeKey(_outboxKey)], isNotNull);
        expect(
          durable[_nativeKey(_scopedOutbox(_first))],
          durable[_nativeKey(_outboxKey)],
        );
        expect(durable.containsKey(_nativeKey(_scopedOutbox(_second))), false);
        expect(native.claimAttempts, [_scope(_first)]);
      } finally {
        native.release();
        await firstSettled.timeout(_limit);
        if (secondSettled != null) await secondSettled.timeout(_limit);
      }
    },
  );

  for (final failure in _ClaimFailure.values) {
    test(
      'a $failure first claim frees the second store to claim legacy',
      () async {
        final native = _install()..firstClaimFailure = failure;
        final firstStore = LocalReviewStore();
        final secondStore = LocalReviewStore();
        final firstActivation = firstStore.activateOwner(_first);
        final firstSettled = _settled(firstActivation);
        Future<void>? secondActivation;
        Future<void>? secondSettled;

        try {
          await native.firstClaimStarted.future.timeout(_limit);
          secondActivation = secondStore.activateOwner(_second);
          secondSettled = _settled(secondActivation);
          await Future<void>(() {});
          native.release();

          await expectLater(
            firstActivation.timeout(_limit),
            throwsA(
              failure == _ClaimFailure.refused
                  ? isA<LocalOutboxWriteException>()
                  : isA<StateError>(),
            ),
          );
          await secondActivation.timeout(_limit);

          expect(firstStore.activeOwnerScope, isNull);
          expect(await _ids(secondStore), ['invented-legacy-review']);
          final durable = await native.getAll();
          expect(durable[_nativeKey(_claimKey)], _scope(_second));
          expect(durable[_nativeKey(_outboxKey)], isNotNull);
          expect(
            durable[_nativeKey(_scopedOutbox(_second))],
            durable[_nativeKey(_outboxKey)],
          );
          expect(durable.containsKey(_nativeKey(_scopedOutbox(_first))), false);
          expect(
            durable.containsKey(_nativeKey('$_migrationKey:${_scope(_first)}')),
            false,
          );
          expect(native.claimAttempts, [_scope(_first), _scope(_second)]);
        } finally {
          native.release();
          await firstSettled.timeout(_limit);
          if (secondSettled != null) await secondSettled.timeout(_limit);
        }
      },
    );
  }

  test(
    'release queued after activation leaves the second store inactive',
    () async {
      final native = _install();
      final firstStore = LocalReviewStore();
      final secondStore = LocalReviewStore();
      final firstActivation = firstStore.activateOwner(_first);
      final firstSettled = _settled(firstActivation);
      Future<void>? secondActivation;
      Future<void>? secondSettled;
      Future<void>? secondRelease;
      Future<void>? releaseSettled;

      try {
        await native.firstClaimStarted.future.timeout(_limit);
        secondActivation = secondStore.activateOwner(_second);
        secondSettled = _settled(secondActivation);
        secondRelease = secondStore.releaseOwner();
        releaseSettled = _settled(secondRelease);
        await Future<void>(() {});
        native.release();
        await Future.wait([
          firstActivation,
          secondActivation,
          secondRelease,
        ]).timeout(_limit);

        expect(firstStore.isActiveOwner(_first), true);
        expect(secondStore.ownerAware, true);
        expect(secondStore.activeOwnerScope, isNull);
        expect(() => secondStore.outbox(), throwsStateError);
        expect(await _ids(firstStore), ['invented-legacy-review']);
        final durable = await native.getAll();
        expect(durable[_nativeKey(_claimKey)], _scope(_first));
        expect(durable.containsKey(_nativeKey(_scopedOutbox(_second))), false);
      } finally {
        native.release();
        await firstSettled.timeout(_limit);
        if (secondSettled != null) await secondSettled.timeout(_limit);
        if (releaseSettled != null) await releaseSettled.timeout(_limit);
      }
    },
  );
}

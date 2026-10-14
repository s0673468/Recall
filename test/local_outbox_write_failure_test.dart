// Refused native writes on the durable study-action store. Every value here is
// invented; the platform double only decides whether a native write succeeds.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

/// In-memory native store that refuses writes to keys containing [refuse].
class _RefusingNative extends InMemorySharedPreferencesStore {
  _RefusingNative([super.values = const {}]) : super.withData();

  String? refuse;
  final refused = <String>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final pattern = refuse;
    if (pattern != null && key.contains(pattern)) {
      refused.add(key);
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

_RefusingNative _install([Map<String, Object> values = const {}]) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _RefusingNative(values);
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

/// Simulates an app restart: drop the Dart-side cache, keep native values.
LocalReviewStore _restart() {
  SharedPreferences.resetStatic();
  return LocalReviewStore();
}

Map<String, dynamic> _review(String id) => {
  'client_id': id,
  'card_id': 4242,
  'rating': 3,
};

void main() {
  test(
    'a refused review append surfaces and the next write persists both',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.refuse = 'recall_outbox_v1';

      await expectLater(
        store.enqueueReview(_review('invented-a')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(native.refused, isNotEmpty);

      // The lock chain survives the failure; a later write is not wedged.
      native.refuse = null;
      expect(await store.enqueueReview(_review('invented-b')), 2);

      final durable = await _restart().outbox();
      expect(durable.map((entry) => entry['client_id']), [
        'invented-a',
        'invented-b',
      ]);
      expect(durable.every((e) => e['delivery_attempted'] == false), isTrue);
    },
  );

  test('a refused attempt marker surfaces before any send', () async {
    final native = _install();
    final store = LocalReviewStore();
    await store.enqueueReview(_review('invented-a'));
    native.refuse = 'recall_outbox_v1';

    await expectLater(
      store.markReviewAttempted('invented-a'),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    native.refuse = null;
    final durable = await _restart().outbox();
    expect(durable.single['delivery_attempted'], isFalse);
  });

  test('a refused catch-up progress write surfaces to the caller', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.refuse = LocalReviewStore.catchUpKey;

    await expectLater(
      store.saveCatchUpState(
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2031-01-02',
          completedToday: 4,
        ),
      ),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(
      (await _restart().loadCatchUpState()).completedToday,
      CatchUpLocalState.none.completedToday,
    );
  });

  test('a refused owner claim leaves no active owner namespace', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.refuse = 'recall_local_state_owner_v1';

    await expectLater(
      store.activateOwner('invented-owner'),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(store.activeOwnerScope, isNull);
    expect(store.ownerAware, isFalse);

    native.refuse = null;
    await store.activateOwner('invented-owner');
    expect(store.isActiveOwner('invented-owner'), isTrue);
  });

  test(
    'a refused legacy migration copy does not activate or mark migrated',
    () async {
      final native = _install({
        'flutter.recall_outbox_v1': '[{"client_id":"legacy-a"}]',
      });
      final store = LocalReviewStore();
      native.refuse = 'recall_outbox_v1:owner:';

      await expectLater(
        store.activateOwner('invented-owner'),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(store.activeOwnerScope, isNull);
      final values = await native.getAll();
      expect(
        values.keys.where((k) => k.contains('recall_local_state_migrated_v1')),
        isEmpty,
      );
      expect(values['flutter.recall_outbox_v1'], isNotNull);
    },
  );

  test('a durable outbox that cannot be decoded fails closed', () async {
    _install({'flutter.recall_outbox_v1': '{not json'});
    final store = LocalReviewStore();

    await expectLater(
      store.outbox(),
      throwsA(isA<LocalOutboxCorruptException>()),
    );
    await expectLater(
      store.enqueueReview(_review('invented-a')),
      throwsA(isA<LocalOutboxCorruptException>()),
    );
    // The lock survives both failures.
    expect(await store.hiddenCardIds(), isEmpty);
  });
}

// Synthetic cross-tab migration checks against the real cached preferences API.
// Direct platform writes stand in for another tab changing native storage.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

const _owner = 'invented-cross-tab-owner';
const _outboxKey = 'recall_outbox_v1';
const _flagKey = 'flag_outbox_v1';
const _hiddenKey = 'recall_hidden_cards_v1';
const _claimKey = 'recall_local_state_owner_v1';
const _migrationKey = 'recall_local_state_migrated_v1';

String _scope() =>
    sha256.convert(utf8.encode(_owner)).toString().substring(0, 24);
String _nativeKey(String key) => 'flutter.$key';
String _scoped(String base) => '$base:owner:${_scope()}';
String _migration() => '$_migrationKey:${_scope()}';

Map<String, dynamic> _review(String id) => {
  'client_id': id,
  'card_id': 42,
  'rating': 3,
};
Map<String, dynamic> _flag(String id) => {
  'client_id': id,
  'card_id': 42,
  'reason': 'synthetic bad card',
};
String _encoded(List<Map<String, dynamic>> entries) => jsonEncode(entries);

InMemorySharedPreferencesStore _install(Map<String, Object> initial) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = InMemorySharedPreferencesStore.withData(initial);
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Future<void> _writeNative(
  InMemorySharedPreferencesStore native,
  String type,
  String key,
  Object value,
) async {
  expect(await native.setValue(type, _nativeKey(key), value), true);
}

Future<List<Object?>> _reviewIds(LocalReviewStore store) async =>
    (await store.outbox()).map((entry) => entry['client_id']).toList();
Future<List<Object?>> _flagIds(LocalReviewStore store) async =>
    (await store.flagOutbox()).map((entry) => entry['client_id']).toList();

Future<LocalReviewStore> _restart() async {
  SharedPreferences.resetStatic();
  final store = LocalReviewStore();
  await store.activateOwner(_owner);
  return store;
}

void main() {
  test(
    'completed migration hydrates a tab with a legacy-only Dart cache',
    () async {
      final legacy = _encoded([_review('invented-legacy-pending')]);
      final native = _install({_nativeKey(_outboxKey): legacy});
      final tabA = LocalReviewStore();
      final oldCache = await SharedPreferences.getInstance();
      expect(oldCache.getString(_outboxKey), legacy);
      expect(oldCache.getString(_scoped(_outboxKey)), isNull);

      // Tab B migrates directly in native storage after tab A has cached only
      // the old key. Its scoped list now has an additional pending review.
      await _writeNative(native, 'String', _claimKey, _scope());
      await _writeNative(
        native,
        'String',
        _scoped(_outboxKey),
        _encoded([
          _review('invented-legacy-pending'),
          _review('invented-tab-b-pending'),
        ]),
      );
      await _writeNative(native, 'Bool', _migration(), true);
      expect(oldCache.getString(_scoped(_outboxKey)), isNull);

      await tabA.activateOwner(_owner);
      expect(await _reviewIds(tabA), [
        'invented-legacy-pending',
        'invented-tab-b-pending',
      ]);
      expect(await tabA.enqueueReview(_review('invented-tab-a-new')), 3);

      final restarted = await _restart();
      expect(await _reviewIds(restarted), [
        'invented-legacy-pending',
        'invented-tab-b-pending',
        'invented-tab-a-new',
      ]);
      final durable = await native.getAll();
      expect(durable[_nativeKey(_claimKey)], _scope());
      expect(durable[_nativeKey(_migration())], true);
      expect(durable[_nativeKey(_outboxKey)], legacy);
    },
  );

  test(
    'same-owner reactivation keeps native review, flag, and hidden changes',
    () async {
      final native = _install({
        _nativeKey(_claimKey): _scope(),
        _nativeKey(_migration()): true,
        _nativeKey(_scoped(_outboxKey)): _encoded([
          _review('invented-initial-pending'),
        ]),
      });
      final tabA = LocalReviewStore();
      await tabA.activateOwner(_owner);
      expect(await _reviewIds(tabA), ['invented-initial-pending']);

      // An independent tab changes native storage while A stays open.
      await _writeNative(
        native,
        'String',
        _scoped(_outboxKey),
        _encoded([
          _review('invented-initial-pending'),
          _review('invented-other-tab-pending'),
        ]),
      );
      await _writeNative(
        native,
        'String',
        _scoped(_flagKey),
        _encoded([_flag('invented-other-tab-flag')]),
      );
      await _writeNative(
        native,
        'String',
        _scoped(_hiddenKey),
        jsonEncode([42]),
      );

      await tabA.activateOwner(_owner);
      expect(await _reviewIds(tabA), [
        'invented-initial-pending',
        'invented-other-tab-pending',
      ]);
      expect(await _flagIds(tabA), ['invented-other-tab-flag']);
      expect(await tabA.hiddenCardIds(), {42});

      expect(await tabA.enqueueReview(_review('invented-tab-a-new')), 3);
      expect(await tabA.enqueueFlag(_flag('invented-tab-a-flag')), 2);
      await tabA.addHiddenCard(84);

      final restarted = await _restart();
      expect(await _reviewIds(restarted), [
        'invented-initial-pending',
        'invented-other-tab-pending',
        'invented-tab-a-new',
      ]);
      expect(await _flagIds(restarted), [
        'invented-other-tab-flag',
        'invented-tab-a-flag',
      ]);
      expect(await restarted.hiddenCardIds(), {42, 84});
    },
  );

  test(
    'enqueue sees a native append without reactivation or a prior read',
    () async {
      final native = _install({
        _nativeKey(_claimKey): _scope(),
        _nativeKey(_migration()): true,
        _nativeKey(_scoped(_outboxKey)): _encoded([
          _review('invented-initial-pending'),
        ]),
      });
      final tabA = LocalReviewStore();
      await tabA.activateOwner(_owner);
      expect(tabA.isActiveOwner(_owner), true);

      // Tab B appends directly to native storage. A does not reactivate or
      // inspect its outbox before making the next local write.
      await _writeNative(
        native,
        'String',
        _scoped(_outboxKey),
        _encoded([
          _review('invented-initial-pending'),
          _review('invented-other-tab-pending'),
        ]),
      );
      expect(await tabA.enqueueReview(_review('invented-tab-a-new')), 3);

      final restarted = await _restart();
      expect(await _reviewIds(restarted), [
        'invented-initial-pending',
        'invented-other-tab-pending',
        'invented-tab-a-new',
      ]);
    },
  );
}

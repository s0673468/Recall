// Positive SERVER acknowledgements only. Every row and backend is synthetic.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

enum _WriteFailure { none, refused, thrownBefore, thrownAfter }

class _Native extends InMemorySharedPreferencesStore {
  _Native(super.values) : super.withData();

  _WriteFailure nextFlagWrite = _WriteFailure.none;
  _WriteFailure nextReviewWrite = _WriteFailure.none;
  bool failReads = false;
  int outboxWrites = 0;

  @override
  Future<Map<String, Object>> getAll() {
    if (failReads) throw StateError('Invented native read refusal');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final flag = key.contains('flag_outbox_v1');
    final review = key.contains('recall_outbox_v1');
    if (!flag && !review) return super.setValue(type, key, value);
    outboxWrites++;
    final failure = flag ? nextFlagWrite : nextReviewWrite;
    if (flag) {
      nextFlagWrite = _WriteFailure.none;
    } else {
      nextReviewWrite = _WriteFailure.none;
    }
    if (failure == _WriteFailure.refused) return false;
    if (failure == _WriteFailure.thrownBefore) {
      throw StateError('Invented write failure before persistence');
    }
    final written = await super.setValue(type, key, value);
    if (failure == _WriteFailure.thrownAfter) {
      throw StateError('Invented write acknowledgement failure');
    }
    return written;
  }
}

Map<String, dynamic> _flag(String id) => {
  'client_id': id,
  'card_id': id == 'invented-a'
      ? 101
      : id == 'invented-b'
      ? 102
      : 103,
  'reason': 'wrong',
};

Map<String, dynamic> _review(String id, {bool attempted = false}) => {
  'client_id': id,
  'card_id': id == 'invented-a' ? 101 : 102,
  'rating': 3,
  'delivery_attempted': attempted,
};

String _key({bool review = false, String? owner}) =>
    'flutter.${review ? 'recall_outbox_v1' : 'flag_outbox_v1'}'
    '${owner == null ? '' : ':owner:$owner'}';

_Native _install({
  List<Map<String, dynamic>> flags = const [],
  List<Map<String, dynamic>> reviews = const [],
}) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _Native({
    _key(): jsonEncode(flags),
    _key(review: true): jsonEncode(reviews),
  });
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Future<List<Map<String, dynamic>>> _persisted(
  _Native native, {
  bool review = false,
  String? owner,
}) async {
  final values = await native.getAll();
  final raw = values[_key(review: review, owner: owner)] as String? ?? '[]';
  return [
    for (final row in jsonDecode(raw) as List)
      Map<String, dynamic>.from(row as Map),
  ];
}

Future<void> _peerWrite(
  _Native native,
  List<Map<String, dynamic>> rows, {
  bool review = false,
  String? owner,
}) async {
  expect(
    await native.setValue(
      'String',
      _key(review: review, owner: owner),
      jsonEncode(rows),
    ),
    isTrue,
  );
}

Future<void> _refusedFlag(
  LocalReviewStore store,
  _Native native,
  Map<String, dynamic> entry, {
  _WriteFailure failure = _WriteFailure.refused,
}) async {
  native.nextFlagWrite = failure;
  await expectLater(
    store.enqueueFlag(entry),
    failure == _WriteFailure.refused
        ? throwsA(isA<LocalOutboxWriteException>())
        : throwsStateError,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failure in [_WriteFailure.refused, _WriteFailure.thrownBefore]) {
    // Contract B (unsaved actions cannot sync): a refused append is hidden and
    // unsent; a later positive ACK for the same action still clears it.
    test(
      'SERVER_ACK_CACHE_FLAG_CLEAR: $failure append clears on server ACK and permits guarded clear',
      () async {
        final a = _flag('invented-a');
        final native = _install();
        final store = LocalReviewStore();
        await _refusedFlag(store, native, a, failure: failure);
        expect(await store.flagOutbox(), isEmpty);
        expect(await _persisted(native), isEmpty);

        // The caller has received the positive server response for this exact A.
        expect(await store.removeAcknowledgedFlags([a]), 0);
        expect(
          await store.flagOutbox(),
          isEmpty,
          reason: 'SERVER_ACK_CACHE_FLAG_CLEAR',
        );
        expect(await _persisted(native), isEmpty);
        await store.clear(requireEmptyOutboxes: true);
        expect(await store.flagOutbox(), isEmpty);
      },
    );
  }

  for (final refusedB in [false, true]) {
    // Contract B (unsaved actions cannot sync): a refused B is hidden and
    // unsent, while a committed B survives A's ACK until its own ACK.
    test(
      'SERVER_ACK_CACHE_FLAG_KEEP_B: unacknowledged B survives A ACK with refused append=$refusedB',
      () async {
        final a = _flag('invented-a');
        final b = _flag('invented-b');
        final native = _install(flags: [a]);
        final store = LocalReviewStore();
        if (refusedB) {
          await _refusedFlag(store, native, b);
        } else {
          await store.enqueueFlag(b);
        }

        expect(
          await store.removeAcknowledgedFlags([a]),
          refusedB ? 0 : 1,
          reason: 'SERVER_ACK_CACHE_FLAG_KEEP_B',
        );
        final visible = refusedB ? const <Map<String, dynamic>>[] : [b];
        expect(await store.flagOutbox(), visible);
        expect(await _persisted(native), visible);
        await expectLater(
          store.clear(requireEmptyOutboxes: true),
          throwsA(
            isA<LocalOutboxNotEmptyException>().having(
              (error) => error.pendingFlags,
              'pending flags',
              1,
            ),
          ),
        );
        expect(await store.flagOutbox(), visible);
      },
    );
  }

  // Contract B (unsaved actions cannot sync): a refused B never comes back from
  // the stale shared cache during another action's ACK merge.
  test(
    'SERVER_ACK_CACHE_FLAG_UNION: native C precedes retained cached B',
    () async {
      final a = _flag('invented-a');
      final b = _flag('invented-b');
      final c = _flag('invented-c');
      final native = _install(flags: [a]);
      final store = LocalReviewStore();
      await _refusedFlag(store, native, b);
      await _peerWrite(native, [a, c]);

      expect(
        await store.removeAcknowledgedFlags([a]),
        1,
        reason: 'SERVER_ACK_CACHE_FLAG_UNION',
      );
      expect(await store.flagOutbox(), [c]);
      expect(await _persisted(native), [c]);
    },
  );

  // Contract B (unsaved actions cannot sync): a refused B stays hidden, even
  // when a stale duplicate ACK arrives in the same owner.
  test(
    'stale duplicate server ACK cannot discard refused B in the same owner',
    () async {
      final a = _flag('invented-a');
      final b = _flag('invented-b');
      final native = _install(flags: [a]);
      final store = LocalReviewStore();
      await store.activateOwner('invented-ack-owner');
      final owner = store.activeOwnerScope!;
      expect(await store.removeAcknowledgedFlags([a], ownerScope: owner), 0);
      await _refusedFlag(store, native, b);
      final writes = native.outboxWrites;

      expect(await store.removeAcknowledgedFlags([a], ownerScope: owner), 0);
      expect(await store.flagOutbox(ownerScope: owner), isEmpty);
      expect(await _persisted(native, owner: owner), isEmpty);
      expect(native.outboxWrites, writes);
      // Only a separately confirmed server ACK for B may remove this cached B.
      expect(await store.removeAcknowledgedFlags([b], ownerScope: owner), 0);
      await store.clear(ownerScope: owner, requireEmptyOutboxes: true);
    },
  );

  test(
    'same-ID full-payload conflicts in cache and native remain recoverable',
    () async {
      final a = {
        ..._flag('invented-a'),
        'detail': {
          'nested': [1, 'invented-original'],
        },
      };
      final changed = {
        ...a,
        'detail': {
          'nested': [1, 'invented-peer-change'],
        },
      };
      final c = _flag('invented-c');
      final native = _install(flags: [a, c]);
      final store = LocalReviewStore();
      expect(await store.flagOutbox(), [a, c]);
      await _peerWrite(native, [changed, c]);

      // C's unambiguous ACK authorizes persistence while both conflicting A
      // variants remain recoverable; A's partial match must not retire either.
      expect(await store.removeAcknowledgedFlags([a, c]), 2);
      expect(await store.flagOutbox(), [changed, a]);
      expect(await _persisted(native), [changed, a]);
    },
  );

  test(
    'integer and string wire-ID conflicts remain distinct across views',
    () async {
      final a = {..._flag('invented-a'), 'client_id': 11};
      final changed = {...a, 'client_id': '11'};
      final c = _flag('invented-c');
      final native = _install(flags: [a, c]);
      final store = LocalReviewStore();
      expect(await store.flagOutbox(), [a, c]);
      await _peerWrite(native, [changed, c]);

      expect(await store.removeAcknowledgedFlags([a, c]), 2);
      expect(await store.flagOutbox(), [changed, a]);
      expect(await _persisted(native), [changed, a]);
    },
  );

  test(
    'identical review copies coalesce without downgrading attempted=true',
    () async {
      final a = _review('invented-a');
      final b = _review('invented-b');
      final attemptedB = _review('invented-b', attempted: true);
      final native = _install(reviews: [a, attemptedB]);
      final store = LocalReviewStore();
      expect(await store.outbox(), [a, attemptedB]);
      await _peerWrite(native, [a, b], review: true);

      expect(await store.removeAcknowledgedReviews([a]), 1);
      expect(await store.outbox(), [attemptedB]);
      expect(await _persisted(native, review: true), [attemptedB]);

      // Missing attempt evidence is uncertain, not a positively unsent event.
      // A peer's false marker must not grant Undo authority to this cached row.
      final unknownB = _review('invented-b')..remove('delivery_attempted');
      final unknownNative = _install(reviews: [a, unknownB]);
      final unknownStore = LocalReviewStore();
      expect(await unknownStore.outbox(), [a, unknownB]);
      await _peerWrite(unknownNative, [a, b], review: true);

      expect(await unknownStore.removeAcknowledgedReviews([a]), 1);
      expect(await unknownStore.outbox(), [unknownB]);
      expect(await _persisted(unknownNative, review: true), [unknownB]);
      expect(await unknownStore.removeEntry('invented-b'), (
        removed: false,
        remaining: 1,
      ));
      expect(await unknownStore.outbox(), [unknownB]);
    },
  );

  // Contract B (unsaved actions cannot sync): the refused review is hidden and
  // unsent, but stays counted so sign-out cannot silently discard it.
  test(
    'flag server ACK leaves unrelated refused review cache intact',
    () async {
      final a = _flag('invented-a');
      final b = _review('invented-b');
      final native = _install(flags: [a]);
      final store = LocalReviewStore();
      native.nextReviewWrite = _WriteFailure.refused;
      await expectLater(
        store.enqueueReview(b),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(await store.outbox(), isEmpty);
      expect(await _persisted(native, review: true), isEmpty);

      expect(await store.removeAcknowledgedFlags([a]), 0);
      expect(await store.flagOutbox(), isEmpty);
      expect(await store.outbox(), isEmpty);
      expect(await _persisted(native, review: true), isEmpty);
      await expectLater(
        store.clear(requireEmptyOutboxes: true),
        throwsA(isA<LocalOutboxNotEmptyException>()),
      );
      expect(await store.outbox(), isEmpty);
    },
  );

  // Contract B (unsaved actions cannot sync): the refused B is never merged
  // back from the stale cache, even after a failed read is retried.
  test(
    'failed native read does not overwrite cached unacknowledged flags',
    () async {
      final a = _flag('invented-a');
      final b = _flag('invented-b');
      final native = _install(flags: [a]);
      final store = LocalReviewStore();
      await _refusedFlag(store, native, b);
      final writes = native.outboxWrites;
      native.failReads = true;
      await expectLater(store.removeAcknowledgedFlags([a]), throwsStateError);
      native.failReads = false;

      expect(native.outboxWrites, writes);
      expect(await store.flagOutbox(), [a]);
      expect(await _persisted(native), [a]);
      expect(await store.removeAcknowledgedFlags([a]), 0);
      expect(await store.flagOutbox(), isEmpty);
      expect(await _persisted(native), isEmpty);
    },
  );

  // Contract B (unsaved actions cannot sync): the refused B stays hidden and
  // unsent through every failed ACK write and its retry. Only A's ACK applies.
  test(
    'failed native ACK write retains B for the same confirmed server ACK retry',
    () async {
      for (final failure in [
        _WriteFailure.refused,
        _WriteFailure.thrownBefore,
        _WriteFailure.thrownAfter,
      ]) {
        final a = _flag('invented-a');
        final b = _flag('invented-b');
        final native = _install(flags: [a]);
        final store = LocalReviewStore();
        await _refusedFlag(store, native, b);
        native.nextFlagWrite = failure;

        await expectLater(
          store.removeAcknowledgedFlags([a]),
          failure == _WriteFailure.refused
              ? throwsA(isA<LocalOutboxWriteException>())
              : throwsStateError,
        );
        // A thrown-after write committed A's removal before its ACK failed.
        final visible = failure == _WriteFailure.thrownAfter ? const [] : [a];
        expect(await store.flagOutbox(), visible);
        expect(await _persisted(native), visible);
        expect(await store.removeAcknowledgedFlags([a]), 0);
        expect(await store.flagOutbox(), isEmpty);
        expect(await _persisted(native), isEmpty);
      }
    },
  );
}

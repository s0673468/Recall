// Synthetic persisted-native snapshots and acknowledged server batches only.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_acceptance_fixture.dart';

enum _Failure { none, refused, thrownBefore, thrownAfter }

class _Native extends InMemorySharedPreferencesStore {
  _Native(Map<String, Object> values) : super.withData(values);

  _Failure nextFailure = _Failure.none;
  bool failRead = false;
  int writes = 0;

  @override
  Future<Map<String, Object>> getAll() {
    if (failRead) throw StateError('Invented native read failure');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!key.contains('outbox_v1')) return super.setValue(type, key, value);
    writes++;
    final failure = nextFailure;
    nextFailure = _Failure.none;
    if (failure == _Failure.refused) return false;
    if (failure == _Failure.thrownBefore) {
      throw StateError('Invented pre-write failure');
    }
    final result = await super.setValue(type, key, value);
    if (failure == _Failure.thrownAfter) {
      throw StateError('Invented lost native drain acknowledgement');
    }
    return result;
  }
}

String _base(bool flag) => flag ? 'flag_outbox_v1' : 'recall_outbox_v1';

Map<String, dynamic> _entry(String id, bool flag) => {
  'client_id': id,
  'card_id': id == 'invented-a' ? 101 : 102,
  if (flag) 'reason': 'wrong',
  if (!flag) 'rating': 3,
  if (!flag) 'delivery_attempted': false,
};

_Native _install(bool flag, List<Map<String, dynamic>> rows) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _Native({'flutter.${_base(flag)}': jsonEncode(rows)});
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Future<List<Map<String, dynamic>>> _persisted(
  _Native native,
  bool flag, {
  String? owner,
}) async {
  final values = await native.getAll();
  final key = 'flutter.${_base(flag)}${owner == null ? '' : ':owner:$owner'}';
  return [
    for (final row in jsonDecode(values[key] as String? ?? '[]') as List)
      Map<String, dynamic>.from(row as Map),
  ];
}

Future<void> _seed(
  _Native native,
  bool flag,
  List<Map<String, dynamic>> rows,
) => native
    .setValue('String', 'flutter.${_base(flag)}', jsonEncode(rows))
    .then((_) {});

Future<int> _drain(
  LocalReviewStore store,
  bool flag,
  List<Map<String, dynamic>> rows, {
  String? owner,
}) => flag
    ? store.removeAcknowledgedFlags(rows, ownerScope: owner)
    : store.removeAcknowledgedReviews(rows, ownerScope: owner);

enum _TransportKind { review, flag, dismiss }

class _AdmissionApi extends SanitizedRecallApi {
  _AdmissionApi()
    : super(
        dataset: SanitizedRecallDataset(
          now: DateTime.utc(2026, 10, 15),
          decks: const [],
          cards: const [],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.empty,
      );

  int sent = 0;

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    sent++;
    return 10101;
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    sent++;
  }

  @override
  Future<void> dismissFlag({
    required int cardId,
    required String clientEventId,
  }) async {
    sent++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final flag in [false, true]) {
    test(
      'server ACK drain reads fresh native state and preserves new suffix: flag=$flag',
      () async {
        final a = _entry('invented-a', flag);
        final b = _entry('invented-b', flag);
        final c = _entry('invented-c', flag);
        final native = _install(flag, [a, b]);
        final store = LocalReviewStore();
        if (flag) {
          await store.flagOutbox();
        } else {
          await store.outbox();
        }
        // The tab's cached list is stale; a separate native writer added C and
        // changed only A's local attempted marker before this server ACK arrived.
        await _seed(native, flag, [
          {...a, 'delivery_attempted': true},
          b,
          c,
        ]);
        expect(await _drain(store, flag, [a]), 2);
        expect((await _persisted(native, flag)).map((e) => e['client_id']), [
          'invented-b',
          'invented-c',
        ]);
        final writes = native.writes;
        expect(await _drain(store, flag, [a]), 2);
        expect(await _drain(store, flag, []), 2);
        expect(native.writes, writes); // Duplicate ACK is an idempotent no-op.
      },
    );

    test(
      'server ACK drain refuses failed native reads before any write: flag=$flag',
      () async {
        final a = _entry('invented-a', flag);
        final b = _entry('invented-b', flag);
        final native = _install(flag, [a, b]);
        final store = LocalReviewStore();
        if (flag) {
          await store.flagOutbox();
        } else {
          await store.outbox();
        }
        final writes = native.writes;
        native.failRead = true;
        await expectLater(_drain(store, flag, [a]), throwsStateError);
        native.failRead = false;
        expect(native.writes, writes);
        expect(await _persisted(native, flag), [a, b]);
      },
    );

    test(
      'refused or unknown native drain preserves B on same-session retry: flag=$flag',
      () async {
        final a = _entry('invented-a', flag);
        final b = _entry('invented-b', flag);
        final native = _install(flag, [a, b]);
        final store = LocalReviewStore();
        for (final failure in [
          _Failure.refused,
          _Failure.thrownBefore,
          _Failure.thrownAfter,
        ]) {
          await _seed(native, flag, [a, b]);
          native.nextFailure = failure;
          await expectLater(
            _drain(store, flag, [a]),
            failure == _Failure.refused
                ? throwsA(isA<LocalOutboxWriteException>())
                : throwsStateError,
          );
          expect((await _persisted(native, flag)).map((e) => e['client_id']), [
            if (failure != _Failure.thrownAfter) 'invented-a',
            'invented-b',
          ]);
          expect(await _drain(store, flag, [a]), 1);
          expect(
            (await _persisted(native, flag)).single['client_id'],
            'invented-b',
          );
        }
      },
    );

    test(
      'server ACK drain stays in captured owner after active-owner replacement: flag=$flag',
      () async {
        final a = _entry('invented-a', flag);
        final native = _install(flag, [a]);
        final store = LocalReviewStore();
        await store.activateOwner('invented-owner-a');
        final ownerA = store.activeOwnerScope!;
        await store.activateOwner('invented-owner-b');
        final ownerB = store.activeOwnerScope!;
        final b = {...a, 'card_id': 999};
        if (flag) {
          await store.enqueueFlag(b);
        } else {
          await store.enqueueReview(b);
        }
        expect(await _drain(store, flag, [a], owner: ownerA), 0);
        expect(await _persisted(native, flag, owner: ownerA), isEmpty);
        expect(await _persisted(native, flag, owner: ownerB), [b]);
      },
    );

    test(
      'same-id payload conflicts, duplicate identities and legacy rows stay queued: flag=$flag',
      () async {
        final a = _entry('invented-a', flag);
        final native = _install(flag, [a]);
        final store = LocalReviewStore();
        final mismatch = {...a, 'card_id': 999};
        final extra = {...a, 'invented_extra_immutable_field': 17};
        for (final rows in [
          [mismatch],
          [extra],
          [a, a],
          [
            {...a, 'client_id': 11},
            {...a, 'client_id': '11'},
          ],
        ]) {
          await _seed(native, flag, rows);
          final writes = native.writes;
          final acknowledged = rows.first['client_id'] == 11
              ? [
                  {...a, 'client_id': 11},
                ]
              : [a];
          expect(await _drain(store, flag, acknowledged), rows.length);
          expect(await _persisted(native, flag), rows);
          expect(native.writes, writes);
        }
        await _seed(native, flag, [a]);
        expect(await _drain(store, flag, [a, a]), 1);
        expect(await _persisted(native, flag), [a]);
        // A legacy record has no stable identity. Retain it even after transport
        // succeeds: it cannot authorize deleting another indistinguishable row.
        final legacyA = {...a}..remove('client_id');
        final legacyB = {...legacyA, 'card_id': 999};
        final identified = _entry('invented-identified', flag);
        await _seed(native, flag, [legacyA, legacyB, identified]);
        expect(await _drain(store, flag, [legacyA, identified]), 2);
        expect(await _persisted(native, flag), [legacyA, legacyB]);
      },
    );

    test(
      'server ACK compares full nested immutable payload and ignores only top-level attempted marker: flag=$flag',
      () async {
        final a = {
          ..._entry('invented-a', flag),
          'invented_nested': {
            'left': 1,
            'right': [2, 3],
          },
        };
        final reordered = {
          ...a,
          'delivery_attempted': true,
          'invented_nested': {
            'right': [2, 3],
            'left': 1,
          },
        };
        final native = _install(flag, [reordered]);
        final store = LocalReviewStore();
        expect(await _drain(store, flag, [a]), 0);
        expect(await _persisted(native, flag), isEmpty);
        final nestedChanged = {
          ...a,
          'invented_nested': {
            'left': 1,
            'right': [2, 4],
          },
        };
        await _seed(native, flag, [nestedChanged]);
        expect(await _drain(store, flag, [a]), 1);
        expect(await _persisted(native, flag), [nestedChanged]);
      },
    );
  }

  for (final kind in _TransportKind.values) {
    test(
      'unidentified or duplicate $kind events never reach transport or disappear',
      () async {
        for (final invalid in [
          'missing',
          'empty',
          'non-scalar',
          'duplicate',
          'wire-collision',
        ]) {
          final flag = kind != _TransportKind.review;
          final a = {
            ..._entry('invented-a', flag),
            if (kind == _TransportKind.dismiss)
              'op': ReviewController.dismissOp,
          };
          if (invalid == 'missing') a.remove('client_id');
          if (invalid == 'empty') a['client_id'] = '';
          if (invalid == 'non-scalar') a['client_id'] = true;
          if (invalid == 'wire-collision') a['client_id'] = 11;
          final rows = [
            a,
            if (invalid == 'duplicate') {...a},
            if (invalid == 'wire-collision') {...a, 'client_id': '11'},
            _entry('invented-b', flag),
          ];
          final native = _install(flag, rows);
          final api = _AdmissionApi();
          final store = LocalReviewStore();
          final controller = ReviewController(
            api: api,
            engine: FsrsEngine(),
            store: store,
            haptics: const ReviewHaptics(),
          );
          try {
            await controller.syncPending();
            await controller.syncPending();
            expect(
              api.sent,
              0,
              reason: 'ACK_DRAIN_UNIDENTIFIED_EVENT_MUST_NOT_TRANSPORT',
            );
            expect(await _persisted(native, flag), rows);
            await expectLater(
              store.clear(requireEmptyOutboxes: true),
              throwsA(isA<LocalOutboxNotEmptyException>()),
            );
            if (!flag) expect(controller.state.pendingSync, rows.length);
          } finally {
            controller.dispose();
            api.disposeFixture();
          }
        }
      },
    );
  }
}

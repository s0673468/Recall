import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

// Only synthetic scheduling records, in-memory preferences and a fake server.
// No sessions, credentials, card content reads or network requests.
const _event = <String, dynamic>{
  'client_id': 'synthetic-duplicate-review',
  'card_id': 1,
  'guid': 'synthetic-guid-1',
  'rating': 3,
  'last_review': '2026-10-22T12:00:00.000Z',
  'due': '2026-10-24T12:00:00.000Z',
  'stability': 2.0,
  'difficulty': 5.0,
  'state': 2,
  'reps': 1,
  'lapses': 0,
  'lapsed': false,
  'device': 'android',
  'delivery_attempted': false,
};

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.empty();

  int reviewWrites = 0;
  bool refuseReviewWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key.contains('recall_outbox_v1')) {
      reviewWrites++;
      if (refuseReviewWrite) return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }

  Future<void> seed(List<Map<String, dynamic>> rows, {String? scope}) async {
    final suffix = scope == null ? '' : ':owner:$scope';
    await super.setValue(
      'String',
      'flutter.recall_outbox_v1$suffix',
      jsonEncode(rows),
    );
  }
}

class _LostReplyApi extends FakeRecallApi {
  _LostReplyApi() : super([testCard()]);

  final committed = Completer<void>();
  final reply = Completer<void>();
  int attempts = 0;

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    final first = attempts++ == 0;
    final receipt = await super.applyReview(entry);
    if (first) {
      committed.complete();
      await reply.future;
    }
    return receipt;
  }
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

  test('single send marks every duplicate in one durable write', () async {
    await native.seed([
      _event,
      {..._event},
    ]);
    final store = LocalReviewStore();

    expect(await store.markReviewAttempted(_event['client_id']!), isTrue);
    expect(native.reviewWrites, 1);
    SharedPreferences.resetStatic();
    final restarted = LocalReviewStore();
    expect((await restarted.outbox()).map((e) => e['delivery_attempted']), [
      true,
      true,
    ]);
    expect(await restarted.removeEntry(_event['client_id']!), (
      removed: false,
      remaining: 2,
    ));
  });

  for (final marker in [true, null, 'unknown']) {
    for (final attemptedFirst in [false, true]) {
      test(
        'Undo preserves mixed copies: $marker, first=$attemptedFirst',
        () async {
          final uncertain = {..._event}..remove('delivery_attempted');
          if (marker != null) uncertain['delivery_attempted'] = marker;
          final rows = attemptedFirst
              ? [uncertain, _event]
              : [_event, uncertain];
          await native.seed(rows);
          final store = LocalReviewStore();

          expect(await store.removeEntry(_event['client_id']!), (
            removed: false,
            remaining: 2,
          ));
          expect(await store.outbox(), rows);
          expect(native.reviewWrites, 0);
        },
      );
    }
  }

  test('Undo removes all copies when every copy was never attempted', () async {
    await native.seed([
      _event,
      {..._event},
    ]);
    final store = LocalReviewStore();
    expect(await store.removeEntry(_event['client_id']!), (
      removed: true,
      remaining: 0,
    ));
    expect(await LocalReviewStore().outbox(), isEmpty);
  });

  test('refused single-send mark leaves every duplicate unattempted', () async {
    await native.seed([
      _event,
      {..._event},
    ]);
    native.refuseReviewWrite = true;
    final store = LocalReviewStore();
    await expectLater(
      store.markReviewAttempted(_event['client_id']!),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(await LocalReviewStore().outbox(), [_event, _event]);
  });

  test(
    'duplicate marks stay bound to the captured owner after switching',
    () async {
      final store = LocalReviewStore();
      await store.activateOwner('synthetic-owner-a');
      final ownerA = store.activeOwnerScope!;
      await native.seed([
        _event,
        {..._event},
      ], scope: ownerA);
      await store.activateOwner('synthetic-owner-b');
      final ownerB = store.activeOwnerScope!;
      await native.seed([_event], scope: ownerB);

      expect(
        await store.markReviewAttempted(
          _event['client_id']!,
          ownerScope: ownerA,
        ),
        isTrue,
      );
      expect(await store.outbox(), [_event]);
      expect(
        (await store.outbox(
          ownerScope: ownerA,
        )).map((e) => e['delivery_attempted']),
        [true, true],
      );
    },
  );

  test(
    'duplicate review timeout cannot undo a committed event; restart retries once',
    () async {
      await native.seed([
        _event,
        {..._event},
      ]);
      final store = LocalReviewStore();
      final api = _LostReplyApi();
      final first = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        reviewSendTimeout: const Duration(milliseconds: 50),
      );
      var firstDisposed = false;
      addTearDown(() {
        if (!api.reply.isCompleted) api.reply.complete();
        if (!firstDisposed) first.dispose();
      });

      final sync = first.syncPending();
      await api.committed.future.timeout(const Duration(seconds: 5));
      // Another store must not report a successful Undo of this delivery id
      // while its server-committed request is still awaiting an acknowledgement.
      expect(await LocalReviewStore().removeEntry(_event['client_id']!), (
        removed: false,
        remaining: 2,
      ));
      await sync.timeout(const Duration(seconds: 5));
      expect(first.state.pendingSync, 2);
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);

      first.dispose();
      firstDisposed = true;
      SharedPreferences.resetStatic();
      final restartedStore = LocalReviewStore();
      final restarted = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: restartedStore,
      );
      addTearDown(restarted.dispose);
      await restarted.syncPending();
      api.reply.complete();
      expect(await restartedStore.outbox(), isEmpty);
      expect(restarted.state.pendingSync, 0);
      expect(api.server.reviewLog, hasLength(1));
      expect(api.server.cards[1]!.reps, 1);
      expect(
        api.server.cards[1]!.due,
        DateTime.parse(_event['due']! as String),
      );
    },
  );
}

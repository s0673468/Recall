// Invented local progress and review IDs only; no provider or user data.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

enum _Failure { refused, thrown }

const _nativeProgressKey = 'flutter.${LocalReviewStore.catchUpKey}';
const _nativeReviewKey = 'flutter.recall_outbox_v1';

CatchUpLocalState _progress(int completed) => CatchUpLocalState(
  mode: CatchUpMode.active,
  dayKey: '2031-01-02',
  completedToday: completed,
);

class _Native extends InMemorySharedPreferencesStore {
  _Native()
    : super.withData({_nativeProgressKey: jsonEncode(_progress(2).toJson())});

  String? failedKey;
  _Failure failure = _Failure.refused;
  final writeError = StateError('invented native write refusal');
  final readError = StateError('invented native read refusal');
  bool failRead = false;
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw readError;
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == failedKey) {
      if (failure == _Failure.thrown) throw writeError;
      return false;
    }
    if (key == _nativeProgressKey && releaseWrite != null) {
      writeStarted!.complete();
      await releaseWrite!.future;
    }
    return super.setValue(valueType, key, value);
  }
}

_Native _install() {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _Native();
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Map<String, dynamic> _review(String id) => {
  'client_id': id,
  'card_id': 4242,
  'rating': 3,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failure in _Failure.values) {
    test(
      'catch-up persisted baseline: ${failure.name} write keeps native progress',
      () async {
        final native = _install();
        final store = LocalReviewStore();
        expect(await store.loadCatchUpState(), _progress(2));
        native
          ..failedKey = _nativeProgressKey
          ..failure = failure;

        await expectLater(
          store.saveCatchUpState(_progress(7)),
          failure == _Failure.refused
              ? throwsA(isA<LocalOutboxWriteException>())
              : throwsA(same(native.writeError)),
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            LocalReviewStore.catchUpKey,
          ),
          jsonEncode(_progress(7).toJson()),
        ); // The same-session cache really contains the refused write.
        expect(
          (await native.getAll())[_nativeProgressKey],
          jsonEncode(_progress(2).toJson()),
        );
        expect(
          await store.loadCatchUpState(),
          _progress(2),
          reason: failure == _Failure.refused
              ? 'CATCHUP_PERSISTED_READ_REFUSED_GHOST'
              : 'CATCHUP_PERSISTED_READ_THROWN_GHOST',
        );
      },
    );
  }

  test('catch-up persisted baseline: peer update is visible', () async {
    final native = _install();
    final store = LocalReviewStore();
    expect(await store.loadCatchUpState(), _progress(2));
    await native.setValue(
      'String',
      _nativeProgressKey,
      jsonEncode(_progress(7).toJson()),
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        LocalReviewStore.catchUpKey,
      ),
      jsonEncode(_progress(2).toJson()),
    ); // The peer changed native storage without touching this writer's cache.

    expect(
      await store.loadCatchUpState(),
      _progress(7),
      reason: 'CATCHUP_PERSISTED_READ_PEER_UPDATE',
    );
  });

  test(
    'catch-up read waits for preceding native write acknowledgement',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      expect(await store.loadCatchUpState(), _progress(2));
      final started = Completer<void>();
      final release = Completer<void>();
      native
        ..writeStarted = started
        ..releaseWrite = release;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final save = store.saveCatchUpState(_progress(7));
      await started.future;
      var readSettled = false;
      final read = store.loadCatchUpState().then((value) {
        readSettled = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(readSettled, isFalse);
      expect(
        (await native.getAll())[_nativeProgressKey],
        jsonEncode(_progress(2).toJson()),
      );

      release.complete();
      await save;
      expect(await read, _progress(7));
    },
  );

  test('catch-up read preserves an unrelated refused review append', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.failedKey = _nativeReviewKey;
    await expectLater(
      store.enqueueReview(_review('invented-a')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect((await native.getAll()).containsKey(_nativeReviewKey), isFalse);
    expect(await store.loadCatchUpState(), _progress(2));
    native.failedKey = null;
    expect(await store.enqueueReview(_review('invented-b')), 2);

    SharedPreferences.resetStatic();
    final durable = await LocalReviewStore().outbox();
    expect(durable.map((entry) => entry['client_id']), [
      'invented-a',
      'invented-b',
    ]);
    expect(
      durable.every((entry) => entry['delivery_attempted'] == false),
      isTrue,
    );
  });

  test(
    'catch-up native read failure preserves progress and pending reviews',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      expect(await store.loadCatchUpState(), _progress(2));
      native.failedKey = _nativeReviewKey;
      await expectLater(
        store.enqueueReview(_review('invented-a')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      native.failRead = true;
      await expectLater(
        store.loadCatchUpState(),
        throwsA(same(native.readError)),
      );
      native.failRead = false;
      expect(await store.loadCatchUpState(), _progress(2));
      native.failedKey = null;
      expect(await store.enqueueReview(_review('invented-b')), 2);

      SharedPreferences.resetStatic();
      expect(
        (await LocalReviewStore().outbox()).map((entry) => entry['client_id']),
        ['invented-a', 'invented-b'],
      );
    },
  );
}

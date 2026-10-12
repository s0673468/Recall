import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

class _NativeAcknowledgement extends InMemorySharedPreferencesStore {
  _NativeAcknowledgement() : super.empty();

  final entered = Completer<void>();
  final release = Completer<void>();
  bool holdCatchUp = true;

  void open() {
    if (!release.isCompleted) release.complete();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (holdCatchUp && key.contains(LocalReviewStore.catchUpKey)) {
      holdCatchUp = false;
      entered.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  test('catch-up read waits for the production store native acknowledgement', () async {
    // Only an invented in-memory platform double. The production store and
    // SharedPreferences memory-cache/native-ack ordering are exercised intact.
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    final native = _NativeAcknowledgement();
    SharedPreferencesStorePlatform.instance = native;
    addTearDown(() {
      native.open();
      SharedPreferencesStorePlatform.instance = previousPlatform;
      SharedPreferences.resetStatic();
    });
    final store = LocalReviewStore();
    final write = store.saveCatchUpState(
      const CatchUpLocalState(
        mode: CatchUpMode.active,
        dayKey: '2026-10-12',
        completedToday: 7,
      ),
    );
    await native.entered.future;
    var readCompleted = false;
    final read = store.loadCatchUpState().then((value) {
      readCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(readCompleted, isFalse,
        reason: 'The memory cache must not bypass the pending native writer');
    native.open();
    await write;
    expect((await read).completedToday, 7);
  });
}

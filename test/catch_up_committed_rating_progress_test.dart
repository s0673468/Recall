// Generated cards and in-memory native preferences only.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

final _day = DateTime.utc(2031, 1, 2, 12);

enum _ProgressFailure { refused, thrown }

User _user(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: _day.toIso8601String(),
);

CatchUpLocalState _progress(DateTime day, int completed) => CatchUpLocalState(
  mode: CatchUpMode.active,
  dayKey: BacklogCatchUp.dayKey(day),
  completedToday: completed,
);

class _Clock {
  DateTime now = _day;
}

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.empty();

  bool failRead = false;
  bool failReadAfterNextReview = false;
  _ProgressFailure? progressFailure;

  // Full and keyed native reads share one fault gate.
  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(_allFlutter());

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) {
    if (failRead) throw StateError('invented native read refusal');
    return super.getAllWithParameters(parameters);
  }

  static GetAllParameters _allFlutter() =>
      GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.'));

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains(LocalReviewStore.catchUpKey)) {
      if (progressFailure == _ProgressFailure.refused) return false;
      if (progressFailure == _ProgressFailure.thrown) {
        throw StateError('invented progress write refusal');
      }
    }
    final stored = await super.setValue(valueType, key, value);
    if (stored &&
        key.startsWith('flutter.recall_outbox_v1:owner:') &&
        failReadAfterNextReview) {
      failReadAfterNextReview = false;
      failRead = true;
    }
    return stored;
  }

  Future<CatchUpLocalState> progress(String scope) async {
    // Inspection bypasses the injected read fault.
    final values = await super.getAllWithParameters(_allFlutter());
    final raw = values['flutter.${LocalReviewStore.catchUpKey}:owner:$scope'];
    return CatchUpLocalState.fromJson(jsonDecode(raw as String));
  }

  Future<List<Map<String, dynamic>>> reviews(String scope) async {
    // Inspection bypasses the injected read fault.
    final values = await super.getAllWithParameters(_allFlutter());
    final raw = values['flutter.recall_outbox_v1:owner:$scope'];
    if (raw == null) return [];
    return [
      for (final entry in jsonDecode(raw as String) as List)
        Map<String, dynamic>.from(entry as Map),
    ];
  }
}

class _Fixture {
  _Fixture(this.native, this.clock, this.api, this.store, this.controller);

  final _Native native;
  final _Clock clock;
  final FakeRecallApi api;
  final LocalReviewStore store;
  final ReviewController controller;

  Future<void> rate() async {
    controller.flip();
    await controller.rate(Rating.good);
  }

  Future<void> loadOffline() async {
    api.beforeQueue = null;
    await controller.load(keepReviewed: false);
    api.beforeQueue = () async => throw StateError('invented offline queue');
    await controller.refresh();
    expect(controller.state.offline, isTrue);
    expect(controller.state.catchUp.isActive, isTrue);
  }
}

Future<_Fixture> _fixture() async {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _Native();
  SharedPreferencesStorePlatform.instance = native;
  final clock = _Clock();
  final api =
      FakeRecallApi([
          for (var id = 1; id <= 8; id++)
            testCard(
              id: id,
              state: 2,
              stability: 4,
              difficulty: 5,
              due: _day.subtract(const Duration(days: 1)),
              lastReview: _day.subtract(const Duration(days: 5)),
              reps: 3,
              cloudSeen: true,
              front: 'Invented progress front $id',
              back: 'Invented progress back $id',
            ),
        ])
        ..user = _user('invented-progress-owner-a')
        ..failApplyReview = true;
  final store = LocalReviewStore();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    clock: () => clock.now,
    haptics: const ReviewHaptics(),
  );
  addTearDown(() async {
    native
      ..failRead = false
      ..progressFailure = null;
    controller.dispose();
    await store.outbox();
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  await store.activateOwner(api.currentUser!.id);
  await store.saveCatchUpState(_progress(clock.now, 2));
  final fixture = _Fixture(native, clock, api, store, controller);
  await fixture.loadOffline();
  expect(controller.state.catchUp.completedToday, 2);
  return fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a committed rating advances when optional native progress read fails',
    () async {
      final f = await _fixture();
      final scope = f.store.activeOwnerScope!;
      f.native.failReadAfterNextReview = true;
      await f.rate();
      expect(f.controller.state.current?.id, 2);
      expect(f.controller.state.reviewedThisSession, 1);
      expect(f.controller.state.catchUp.completedToday, 3);
      expect(f.controller.rateInFlight, isFalse);
      final first = await f.native.reviews(scope);
      expect(first.map((entry) => entry['card_id']), [1]);
      final originalId = first.single['client_id'];

      f.native.failRead = false;
      // Retrying the previous tap cannot mint another event for the old card.
      await f.controller.rate(Rating.good);
      expect((await f.native.reviews(scope)).single['client_id'], originalId);
      await f.rate();
      final pending = await f.native.reviews(scope);
      expect(pending.map((entry) => entry['card_id']), [1, 2]);
      expect(pending.map((entry) => entry['client_id']).toSet(), hasLength(2));
      expect(pending.first['client_id'], originalId);
      expect(f.controller.state.catchUp.completedToday, 4);
    },
  );

  for (final failure in _ProgressFailure.values) {
    test(
      'a ${failure.name} progress save cannot undercount the next rating',
      () async {
        final f = await _fixture();
        final scope = f.store.activeOwnerScope!;
        f.native.progressFailure = failure;
        await f.rate();
        expect(f.controller.state.catchUp.completedToday, 3);
        expect(await f.native.progress(scope), _progress(f.clock.now, 2));
        f.native.progressFailure = null;
        await f.rate();
        expect(f.controller.state.catchUp.completedToday, 4);
        expect(await f.native.progress(scope), _progress(f.clock.now, 4));
        expect(
          (await f.native.reviews(scope)).map((entry) => entry['card_id']),
          [1, 2],
        );
      },
    );
  }

  test(
    'failed native read after midnight cannot reuse the previous day count',
    () async {
      final f = await _fixture();
      final scope = f.store.activeOwnerScope!;
      f.native.progressFailure = _ProgressFailure.refused;
      await f.rate();
      expect(f.controller.state.catchUp.completedToday, 3);
      f.clock.now = f.clock.now.add(const Duration(days: 1));
      f.native
        ..progressFailure = null
        ..failReadAfterNextReview = true;
      await f.rate();
      expect(f.controller.state.current?.id, 3);
      expect(f.controller.state.catchUp.completedToday, 1);
      expect(await f.native.progress(scope), _progress(f.clock.now, 1));
    },
  );

  for (final switchOwner in [false, true]) {
    test(
      'a replacement ${switchOwner ? 'owner' : 'load'} does not inherit an older rating floor',
      () async {
        final f = await _fixture();
        final ownerA = f.store.activeOwnerScope!;
        f.native.progressFailure = _ProgressFailure.refused;
        await f.rate();
        expect(f.controller.state.catchUp.completedToday, 3);
        f.native.progressFailure = null;
        if (switchOwner) {
          f.api.user = _user('invented-progress-owner-b');
          await f.store.activateOwner(f.api.currentUser!.id);
          await f.store.saveCatchUpState(_progress(f.clock.now, 1));
        }
        await f.loadOffline();
        final baseline = switchOwner ? 1 : 2;
        expect(f.controller.state.catchUp.completedToday, baseline);
        f.native.failReadAfterNextReview = true;
        await f.rate();
        expect(f.controller.state.catchUp.completedToday, baseline + 1);
        expect(
          await f.native.progress(f.store.activeOwnerScope!),
          _progress(f.clock.now, baseline + 1),
        );
        if (switchOwner) {
          expect(
            (await f.native.reviews(ownerA)).map((entry) => entry['card_id']),
            [1],
          );
        }
      },
    );
  }

  test('Undo decreases the floor before the next committed rating', () async {
    final f = await _fixture();
    final scope = f.store.activeOwnerScope!;
    await f.rate();
    expect(f.controller.state.catchUp.completedToday, 3);
    final undoneId = (await f.native.reviews(scope)).single['client_id'];
    await f.controller.undo();
    expect(f.controller.state.current?.id, 1);
    expect(f.controller.state.catchUp.completedToday, 2);
    expect(await f.native.progress(scope), _progress(f.clock.now, 2));
    expect(await f.native.reviews(scope), isEmpty);

    f.native.failReadAfterNextReview = true;
    await f.rate();
    expect(f.controller.state.current?.id, 2);
    expect(f.controller.state.catchUp.completedToday, 3);
    expect(await f.native.progress(scope), _progress(f.clock.now, 3));
    final pending = await f.native.reviews(scope);
    expect(pending.single['card_id'], 1);
    expect(pending.single['client_id'], isNot(undoneId));
  });

  test(
    'acknowledged peer progress can raise the current local floor',
    () async {
      final f = await _fixture();
      final scope = f.store.activeOwnerScope!;
      await f.rate();
      await f.native.setValue(
        'String',
        'flutter.${LocalReviewStore.catchUpKey}:owner:$scope',
        jsonEncode(_progress(f.clock.now, 7).toJson()),
      );
      await f.rate();
      expect(f.controller.state.catchUp.completedToday, 8);
      expect(await f.native.progress(scope), _progress(f.clock.now, 8));
    },
  );
}

// Synthetic regression for a same-owner refresh racing a settings edit.
// The native snapshot is captured before the pending write and returned after
// SharedPreferences has already cached that write.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

const _owner = 'invented-settings-race-owner';
const _waitLimit = Duration(seconds: 5);

String _nativeKey(String key) => 'flutter.$key';

class _SnapshotNative extends InMemorySharedPreferencesStore {
  _SnapshotNative(super.values) : super.withData();

  final snapshotCaptured = Completer<void>();
  final releaseSnapshot = Completer<void>();
  final pendingWriteStarted = Completer<void>();
  final releasePendingWrite = Completer<void>();
  bool holdNextRead = false;
  bool holdNextPendingWrite = false;
  String? pendingKey;

  // Full and keyed native reads share one hold, once per read.
  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final snapshot = await super.getAllWithParameters(parameters);
    if (holdNextRead) {
      holdNextRead = false;
      snapshotCaptured.complete();
      await releaseSnapshot.future;
    }
    return snapshot;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (holdNextPendingWrite && key == pendingKey) {
      holdNextPendingWrite = false;
      pendingWriteStarted.complete();
      await releasePendingWrite.future;
    }
    return super.setValue(valueType, key, value);
  }

  void releaseAll() {
    if (!releaseSnapshot.isCompleted) releaseSnapshot.complete();
    if (!releasePendingWrite.isCompleted) releasePendingWrite.complete();
  }
}

class _PrefsApi extends RecallApi {
  _PrefsApi()
    : super(
        SupabaseClient(
          'https://recall.invalid',
          'synthetic-publishable-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  final user = User(
    id: _owner,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime.utc(2026).toIso8601String(),
  );
  Map<String, dynamic> cloud = const RecallPrefs().toJson();
  final saved = <Map<String, dynamic>>[];
  int fetches = 0;

  @override
  User get currentUser => user;

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    fetches++;
    return Map<String, dynamic>.from(cloud);
  }

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    final copy = Map<String, dynamic>.from(value);
    saved.add(copy);
    cloud = copy;
  }
}

void main() {
  test(
    'same-owner migration check cannot erase an in-flight settings edit',
    () async {
      final localKey = RecallPrefsController.localKeyForOwner(_owner);
      final pendingKey = RecallPrefsController.pendingKeyForOwner(_owner);
      final previous = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      final native = _SnapshotNative({
        _nativeKey(localKey): jsonEncode(const RecallPrefs().toJson()),
      });
      SharedPreferencesStorePlatform.instance = native;
      addTearDown(() {
        native.releaseAll();
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      });

      final api = _PrefsApi();
      addTearDown(api.client.dispose);
      final store = LocalReviewStore();
      final prefs = RecallPrefsController(api: api);
      addTearDown(prefs.dispose);

      await store.activateOwner(_owner);
      await prefs.activateOwner(_owner);
      expect(store.isActiveOwner(_owner), isTrue);
      expect(prefs.value.newLimitDefault, 20);
      final storage = await SharedPreferences.getInstance();
      expect(storage.getString(pendingKey), isNull);
      final durableBeforeRace = await native.getAll();
      expect(
        durableBeforeRace.entries
            .where(
              (entry) => entry.key.startsWith(
                _nativeKey('recall_local_state_migrated_v1:'),
              ),
            )
            .map((entry) => entry.value)
            .toList(),
        [true],
        reason: 'The owner migration must already be complete.',
      );

      native
        ..pendingKey = _nativeKey(pendingKey)
        ..holdNextRead = true
        ..holdNextPendingWrite = true;
      final reactivation = store.activateOwner(_owner);
      final settledReactivation = reactivation.then<void>(
        (_) {},
        onError: (_) {},
      );
      Future<void>? update;
      Future<void>? settledUpdate;
      try {
        await native.snapshotCaptured.future.timeout(_waitLimit);
        update = prefs.update(const RecallPrefs(newLimitDefault: 7));
        settledUpdate = update.then<void>((_) {}, onError: (_) {});
        await native.pendingWriteStarted.future.timeout(_waitLimit);

        // The real SharedPreferences setter has cached 7, although native
        // persistence is still blocked and the captured read still says 20.
        expect(
          RecallPrefs.fromJson(
            jsonDecode(storage.getString(pendingKey)!),
          ).newLimitDefault,
          7,
        );
        expect((await native.getAll())[_nativeKey(pendingKey)], isNull);

        native.releaseSnapshot.complete();
        await reactivation.timeout(_waitLimit);
        native.releasePendingWrite.complete();
        await update.timeout(_waitLimit);
      } finally {
        native.releaseAll();
        await settledReactivation.timeout(_waitLimit);
        if (settledUpdate != null) await settledUpdate.timeout(_waitLimit);
      }

      expect(prefs.value.newLimitDefault, 7);
      expect(api.saved, hasLength(1));
      expect(api.saved.single['new_limit_default'], 7);
      expect(api.cloud['new_limit_default'], 7);
      expect(
        api.fetches,
        0,
        reason: 'The pending edit must replay before a cloud read.',
      );
      expect(storage.getString(pendingKey), isNull);
      expect(
        RecallPrefs.fromJson(
          jsonDecode(storage.getString(localKey)!),
        ).newLimitDefault,
        7,
      );
    },
  );
}

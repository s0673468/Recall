import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

// Invented settings and owner only. This fake has no HTTP client or credentials.
class _SettingsApi implements RecallApi {
  final saved = <Map<String, dynamic>>[];
  RecallPrefs cloud = const RecallPrefs(newLimitDefault: 17);

  @override
  User get currentUser => User(
    id: 'synthetic-owner',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-10-21T00:00:00Z',
  );

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async => cloud.toJson();

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    saved.add(Map.of(value));
    cloud = RecallPrefs.fromJson(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RefusingStorage extends InMemorySharedPreferencesStore {
  _RefusingStorage() : super.withData({});

  String? refusedKey;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == refusedKey) return Future.value(false);
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'synthetic-owner';
  final pendingKey = RecallPrefsController.pendingKeyForOwner(owner);
  final localKey = RecallPrefsController.localKeyForOwner(owner);

  for (final malformed in ['null', '[]', '42', 'true', '"invalid"']) {
    test(
      'non-object pending JSON $malformed never becomes a cloud write',
      () async {
        SharedPreferences.setMockInitialValues({
          pendingKey: malformed,
          localKey: jsonEncode(const RecallPrefs(newLimitDefault: 8).toJson()),
        });
        final api = _SettingsApi();
        final controller = RecallPrefsController(api: api);
        addTearDown(controller.dispose);

        await controller.activateOwner(owner);
        final hydratedLimit = controller.value.newLimitDefault;
        await controller.syncOwner();

        expect(api.saved, isEmpty);
        expect(hydratedLimit, 8);
        expect(controller.value, api.cloud);
        final storage = await SharedPreferences.getInstance();
        expect(storage.getString(pendingKey), isNull);
        expect(
          storage.getString(
            RecallPrefsController.corruptPendingKeyForOwner(owner),
          ),
          malformed,
        );
      },
    );
  }

  test(
    'a non-object local mirror is discarded before cloud recovery',
    () async {
      SharedPreferences.setMockInitialValues({localKey: '[]'});
      final api = _SettingsApi();
      final controller = RecallPrefsController(api: api);
      addTearDown(controller.dispose);

      await controller.activateOwner(owner);
      expect(controller.hasStoredPrefs, isFalse);
      expect(controller.value, const RecallPrefs());
      await controller.syncOwner();
      expect(controller.value, api.cloud);
      expect(api.saved, isEmpty);
    },
  );

  for (final refusedKey in [pendingKey, localKey]) {
    test('same-value retry repairs a refused write to $refusedKey', () async {
      final previous = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      final native = _RefusingStorage();
      SharedPreferencesStorePlatform.instance = native;
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      });
      final api = _SettingsApi();
      final controller = RecallPrefsController(api: api);
      addTearDown(controller.dispose);
      await controller.activateOwner(owner);
      const requested = RecallPrefs(newLimitDefault: 9);

      native.refusedKey = 'flutter.$refusedKey';
      await expectLater(controller.update(requested), throwsStateError);
      expect(api.saved, isEmpty);
      native.refusedKey = null;
      await controller.update(requested);

      expect(api.saved, [requested.toJson()]);
      // Drop the optimistic SharedPreferences cache and read native truth.
      SharedPreferences.resetStatic();
      final restarted = RecallPrefsController(api: api);
      addTearDown(restarted.dispose);
      await restarted.activateOwner(owner);
      expect(restarted.value, requested);
      final storage = await SharedPreferences.getInstance();
      expect(storage.getString(pendingKey), isNull);
      expect(storage.getString(localKey), jsonEncode(requested.toJson()));
    });
  }

  test('an already durable identical update needs no second write', () async {
    SharedPreferences.setMockInitialValues({});
    final api = _SettingsApi();
    final controller = RecallPrefsController(api: api);
    addTearDown(controller.dispose);
    await controller.activateOwner(owner);
    const requested = RecallPrefs(newLimitDefault: 9);

    await controller.update(requested);
    await controller.update(requested);

    expect(controller.value, requested);
    expect(api.saved, [requested.toJson()]);
  });

  test(
    'the same value can be retried after local storage is unavailable',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await SharedPreferences.getInstance();
      final api = _SettingsApi();
      var unavailable = false;
      final controller = RecallPrefsController(
        api: api,
        prefsLoader: () async {
          if (unavailable) throw StateError('synthetic storage unavailable');
          return storage;
        },
      );
      addTearDown(controller.dispose);
      await controller.activateOwner(owner);
      const requested = RecallPrefs(newLimitDefault: 9);

      unavailable = true;
      await expectLater(controller.update(requested), throwsStateError);
      expect(api.saved, isEmpty);
      unavailable = false;
      await controller.update(requested);

      expect(api.saved, [requested.toJson()]);
      expect(controller.value, requested);
      expect(storage.getString(localKey), jsonEncode(requested.toJson()));
      expect(storage.getString(pendingKey), isNull);
      final restarted = RecallPrefsController(api: api);
      addTearDown(restarted.dispose);
      await restarted.activateOwner(owner);
      expect(restarted.value, requested);
    },
  );
}

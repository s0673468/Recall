import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Only synthetic owners and settings; no transport or credentials.
class _SettingsApi implements RecallApi {
  String owner = 'synthetic-a';
  final saved = <Map<String, dynamic>>[];
  Future<void> Function()? beforeSave;

  @override
  User get currentUser => User(
    id: owner,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
  );

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    await beforeSave?.call();
    saved.add(Map.of(value));
  }

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async =>
      throw StateError('synthetic offline read');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage extends InMemorySharedPreferencesStore {
  _Storage(super.data) : super.withData();

  String? refusedKey;
  bool throwOnRefusal = false;
  void Function(String key, Object value)? afterWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == refusedKey) {
      if (throwOnRefusal) throw StateError('synthetic write failure');
      return false;
    }
    final accepted = await super.setValue(valueType, key, value);
    afterWrite?.call(key, value);
    return accepted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'synthetic-a';
  const previous = RecallPrefs(newLimitDefault: 20, desiredRetention: 0.9);
  const requested = RecallPrefs(newLimitDefault: 4, desiredRetention: 0.85);
  final localKey = RecallPrefsController.localKeyForOwner(owner);
  final pendingKey = RecallPrefsController.pendingKeyForOwner(owner);
  late _Storage native;
  late _SettingsApi api;
  late RecallPrefsController controller;

  setUp(() async {
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    native = _Storage({'flutter.$localKey': jsonEncode(previous.toJson())});
    SharedPreferencesStorePlatform.instance = native;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previousPlatform;
      SharedPreferences.resetStatic();
    });
    api = _SettingsApi();
    controller = RecallPrefsController(api: api);
    addTearDown(controller.dispose);
    await controller.activateOwner(owner);
    expect(controller.value, previous);
  });

  for (final throws in [false, true]) {
    test(
      'sync repairs a failed mirror before offline account return (throws=$throws)',
      () async {
        native
          ..refusedKey = 'flutter.$localKey'
          ..throwOnRefusal = throws;
        await expectLater(controller.update(requested), throwsStateError);
        expect(api.saved, isEmpty);

        native.refusedKey = null;
        await controller.syncOwner();
        expect(api.saved, [requested.toJson()]);

        final storage = await SharedPreferences.getInstance();
        await storage.reload();
        expect(storage.getString(pendingKey), isNull);
        expect(storage.getString(localKey), jsonEncode(requested.toJson()));

        await controller.releaseOwner();
        api.owner = 'synthetic-b';
        await controller.activateOwner(api.owner);
        expect(controller.value, const RecallPrefs());
        await controller.releaseOwner();
        api.owner = owner;
        await controller.activateOwner(owner);
        expect(controller.value, requested);

        // Also restore from backend storage with a fresh preferences cache.
        SharedPreferences.resetStatic();
        final restarted = RecallPrefsController(api: api);
        addTearDown(restarted.dispose);
        await restarted.activateOwner(owner);
        expect(restarted.value, requested);
      },
    );

    test(
      'failed mirror repair retains accepted pending settings for retry (throws=$throws)',
      () async {
        native
          ..refusedKey = 'flutter.$localKey'
          ..throwOnRefusal = throws;
        await expectLater(controller.update(requested), throwsStateError);

        // The server accepts the settings while the mirror is still unwritable.
        await controller.syncOwner();
        expect(api.saved, [requested.toJson()]);
        final storage = await SharedPreferences.getInstance();
        await storage.reload();
        expect(storage.getString(pendingKey), jsonEncode(requested.toJson()));
        expect(storage.getString(localKey), jsonEncode(previous.toJson()));

        SharedPreferences.resetStatic();
        final restarted = RecallPrefsController(api: api);
        addTearDown(restarted.dispose);
        await restarted.activateOwner(owner);
        expect(restarted.value, requested);

        native.refusedKey = null;
        await restarted.syncOwner();
        expect(api.saved, [requested.toJson(), requested.toJson()]);
        final repaired = await SharedPreferences.getInstance();
        await repaired.reload();
        expect(repaired.getString(pendingKey), isNull);
        expect(repaired.getString(localKey), jsonEncode(requested.toJson()));
      },
    );
  }

  test('an older accepted replay cannot overwrite a newer mirror', () async {
    final started = Completer<void>();
    final finishSave = Completer<void>();
    final newerPersisted = Completer<void>();
    api.beforeSave = () {
      started.complete();
      return finishSave.future;
    };

    final first = controller.update(requested);
    await started.future;
    const newer = RecallPrefs(newLimitDefault: 12, desiredRetention: 0.95);
    native.afterWrite = (key, value) {
      if (key == 'flutter.$localKey' && value == jsonEncode(newer.toJson())) {
        newerPersisted.complete();
      }
    };
    // Keep the newer edit pending once the older replay finishes.
    api.beforeSave = () async => throw StateError('synthetic offline save');
    final second = controller.update(newer);
    await newerPersisted.future;
    finishSave.complete();
    await Future.wait([first, second]);

    final storage = await SharedPreferences.getInstance();
    await storage.reload();
    expect(storage.getString(pendingKey), jsonEncode(newer.toJson()));
    expect(storage.getString(localKey), jsonEncode(newer.toJson()));
    expect(api.saved, [requested.toJson()]);
  });
}

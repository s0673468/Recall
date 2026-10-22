import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No transport, credentials or personal data: only synthetic settings/owners.
class _SettingsApi implements RecallApi {
  String owner = 'synthetic-a';
  final saved = <Map<String, dynamic>>[];
  int fetches = 0;

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
    saved.add(Map.of(value));
  }

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    fetches++;
    // Deliberately lagging cloud read, like a replica after a write.
    return const RecallPrefs(newLimitDefault: 30).toJson();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage extends InMemorySharedPreferencesStore {
  _Storage() : super.withData({});

  String? refusedWrite;
  String? refusedRemoval;
  bool throws = false;
  bool readsUnavailable = false;

  @override
  Future<Map<String, Object>> getAll() {
    if (readsUnavailable) throw StateError('synthetic read failure');
    return super.getAll();
  }

  Future<bool> _refuse() async {
    if (throws) throw StateError('synthetic storage failure');
    return false;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      key == refusedWrite ? _refuse() : super.setValue(valueType, key, value);

  @override
  Future<bool> remove(String key) =>
      key == refusedRemoval ? _refuse() : super.remove(key);
}

class _ReminderPlatform implements StudyReminderPlatform {
  final applied = <StudyReminderSettings>[];

  @override
  Future<void> apply(
    StudyReminderSettings settings, {
    required int? dueCount,
    required bool studiedToday,
  }) async {
    applied.add(settings);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<bool> requestPermission() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'synthetic-a';
  final pendingKey = RecallPrefsController.pendingKeyForOwner(owner);
  final localKey = RecallPrefsController.localKeyForOwner(owner);
  const requested = RecallPrefs(newLimitDefault: 4, desiredRetention: 0.85);

  for (final throws in [false, true]) {
    group('storage refusal throws=$throws', () {
      late _Storage native;

      setUp(() {
        final previous = SharedPreferencesStorePlatform.instance;
        SharedPreferences.resetStatic();
        native = _Storage()..throws = throws;
        SharedPreferencesStorePlatform.instance = native;
        addTearDown(() {
          SharedPreferencesStorePlatform.instance = previous;
          SharedPreferences.resetStatic();
        });
      });

      test(
        'refused pending write cannot later sync from phantom cache',
        () async {
          final api = _SettingsApi();
          final controller = RecallPrefsController(api: api);
          addTearDown(controller.dispose);
          await controller.activateOwner(owner);
          native.refusedWrite = 'flutter.$pendingKey';

          await expectLater(controller.update(requested), throwsStateError);
          native.refusedWrite = null;
          await controller.syncOwner();

          expect(api.saved, isEmpty);
          expect(api.fetches, 1);
          final storage = await SharedPreferences.getInstance();
          expect(storage.getString(pendingKey), isNull);
          expect(controller.value.newLimitDefault, 30);
        },
      );

      test(
        'refused pending removal remains authoritative on next sync',
        () async {
          final api = _SettingsApi();
          final controller = RecallPrefsController(api: api);
          addTearDown(controller.dispose);
          await controller.activateOwner(owner);
          native.refusedRemoval = 'flutter.$pendingKey';

          await controller.update(requested);
          native.refusedRemoval = null;
          await controller.syncOwner();

          expect(api.saved, [requested.toJson(), requested.toJson()]);
          expect(api.fetches, 0);
          expect(controller.value, requested);
          // Verify persisted truth after dropping the shared optimistic cache.
          SharedPreferences.resetStatic();
          final restarted = RecallPrefsController(api: api);
          addTearDown(restarted.dispose);
          await restarted.activateOwner(owner);
          expect(restarted.value, requested);
          final storage = await SharedPreferences.getInstance();
          expect(storage.getString(pendingKey), isNull);
          expect(storage.getString(localKey), jsonEncode(requested.toJson()));
        },
      );
      test(
        'failed readback cannot authorize a phantom pending write',
        () async {
          final api = _SettingsApi();
          final controller = RecallPrefsController(api: api);
          addTearDown(controller.dispose);
          await controller.activateOwner(owner);
          native.refusedWrite = 'flutter.$pendingKey';
          native.readsUnavailable = true;

          await expectLater(controller.update(requested), throwsStateError);
          native.refusedWrite = null;
          await controller.syncOwner();
          expect(api.saved, isEmpty);
          expect(api.fetches, 0);

          native.readsUnavailable = false;
          await controller.syncOwner();
          expect(api.saved, isEmpty);
          expect(api.fetches, 1);
          expect(controller.value.newLimitDefault, 30);
        },
      );
    });
  }

  test(
    'numeric overflow in upgraded JSON preserves valid sibling settings',
    () {
      final parsed = RecallPrefs.fromJson(
        jsonDecode(
          '{"new_limit_default":1e999,"desired_retention":1e999,'
          '"new_order":"random","per_deck":'
          '{"7":{"new_limit":-1e999},"8":{"new_limit":6}}}',
        ),
      );
      expect(parsed.newLimitDefault, RecallPrefs.defaultNewLimit);
      expect(parsed.desiredRetention, RecallPrefs.defaultRetention);
      expect(parsed.newOrder, NewOrder.random);
      expect(parsed.perDeck, {7: RecallPrefs.defaultNewLimit, 8: 6});
      expect(() => jsonEncode(parsed.toJson()), returnsNormally);
    },
  );

  test('non-finite numeric preferences fall back instead of throwing', () {
    for (final number in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(
        RecallPrefs.fromJson({
          'new_limit_default': number,
          'desired_retention': number,
        }),
        const RecallPrefs(),
      );
    }
  });

  for (final field in ['enabled', 'hour', 'minute']) {
    test('reminder tolerates an upgraded $field with the wrong type', () async {
      SharedPreferences.setMockInitialValues({
        'recall_study_reminder_enabled:$owner': true,
        'recall_study_reminder_hour:$owner': 21,
        'recall_study_reminder_minute:$owner': 15,
        'recall_study_reminder_$field:$owner': 'invalid',
      });
      final platform = _ReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);

      await controller.activateOwner(owner);

      expect(controller.value.enabled, field != 'enabled');
      expect(controller.value.hour, field == 'hour' ? 19 : 21);
      expect(controller.value.minute, field == 'minute' ? 0 : 15);
      // Recovery remains usable and stays scoped when switching accounts.
      await controller.setTime(hour: 20, minute: 45);
      await controller.setEnabled(true);
      await controller.activateOwner('synthetic-b');
      expect(controller.value.enabled, isFalse);
      await controller.activateOwner(owner);
      expect(controller.value.enabled, isTrue);
      expect(controller.value.formattedTime, '20:45');
      await controller.reconcile(
        dueCount: 2,
        lastReviewedAt: null,
        reviewActivityKnown: true,
      );
      expect(platform.applied.last.formattedTime, '20:45');
    });
  }

  for (final invalid in <Object>[
    true,
    42,
    <String>['invalid'],
  ]) {
    test(
      'wrongly typed study mirrors and pending values recover ($invalid)',
      () async {
        SharedPreferences.setMockInitialValues({
          localKey: invalid,
          pendingKey: invalid,
        });
        final api = _SettingsApi();
        final controller = RecallPrefsController(api: api);
        addTearDown(controller.dispose);

        await controller.activateOwner(owner);
        expect(controller.hasStoredPrefs, isFalse);
        await controller.syncOwner();

        expect(api.saved, isEmpty);
        expect(controller.value.newLimitDefault, 30);
        final storage = await SharedPreferences.getInstance();
        expect(storage.get(pendingKey), isNull);
        expect(
          jsonDecode(
            storage.getString(
              RecallPrefsController.corruptPendingKeyForOwner(owner),
            )!,
          ),
          invalid,
        );
      },
    );
  }
}

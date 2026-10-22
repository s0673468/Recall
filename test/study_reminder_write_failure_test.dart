import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _RefusingPreferences extends InMemorySharedPreferencesStore {
  _RefusingPreferences() : super.withData({});

  String? refusedKey;
  bool throwOnWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == refusedKey) {
      if (throwOnWrite) throw StateError('invented storage failure');
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

class _ReminderPlatform implements StudyReminderPlatform {
  bool scheduled = false;
  @override
  Future<void> apply(
    StudyReminderSettings settings, {
    required int? dueCount,
    required bool studiedToday,
  }) async {
    scheduled = settings.enabled && (dueCount ?? 0) > 0 && !studiedToday;
  }

  @override
  Future<void> cancel() async {
    scheduled = false;
  }

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<bool> requestPermission() async => true;
}

void main() {
  test(
    'failed enable leaves no native alarm or acknowledged setting',
    () async {
      final original = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      final native = _RefusingPreferences();
      SharedPreferencesStorePlatform.instance = native;
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = original;
        SharedPreferences.resetStatic();
      });
      final platform = _ReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);
      await controller.initialize(ownerId: 'invented-owner');
      await controller.reconcile(
        dueCount: 3,
        lastReviewedAt: null,
        reviewActivityKnown: true,
      );
      native.refusedKey =
          'flutter.recall_study_reminder_enabled:invented-owner';

      await expectLater(controller.setEnabled(true), throwsStateError);

      expect(controller.value.enabled, isFalse);
      expect(platform.scheduled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('recall_study_reminder_enabled:invented-owner'),
        isNull,
      );

      native.refusedKey = null;
      expect(await controller.setEnabled(true), isTrue);
      expect(platform.scheduled, isTrue);
    },
  );

  for (final field in ['enabled', 'hour', 'minute']) {
    for (final throws in [false, true]) {
      test(
        'failed $field write (throws=$throws) never reports a saved change',
        () async {
          final original = SharedPreferencesStorePlatform.instance;
          SharedPreferences.resetStatic();
          final native = _RefusingPreferences();
          SharedPreferencesStorePlatform.instance = native;
          addTearDown(() {
            SharedPreferencesStorePlatform.instance = original;
            SharedPreferences.resetStatic();
          });
          final platform = _ReminderPlatform();
          final controller = StudyReminderController(platform: platform);
          addTearDown(controller.dispose);
          await controller.initialize(ownerId: 'invented-owner');
          await controller.reconcile(
            dueCount: 3,
            lastReviewedAt: null,
            reviewActivityKnown: true,
          );
          await controller.setEnabled(true);
          expect(platform.scheduled, isTrue);
          native.refusedKey =
              'flutter.recall_study_reminder_$field:invented-owner';
          native.throwOnWrite = throws;

          await expectLater(
            field == 'enabled'
                ? controller.setEnabled(false)
                : controller.setTime(
                    hour: field == 'hour' ? 20 : 19,
                    minute: 45,
                  ),
            throwsStateError,
          );

          // The rejected value must not become the controller's acknowledged state
          // or remain in the optimistic SharedPreferences cache on a later sign-in.
          expect(platform.scheduled, isFalse);
          expect(controller.value.enabled, isTrue);
          expect(controller.value.hour, 19);
          expect(controller.value.minute, 0);
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.get('recall_study_reminder_$field:invented-owner'),
            field == 'enabled' ? true : (field == 'hour' ? 19 : 0),
          );

          native.refusedKey = null;
          if (field == 'enabled') {
            expect(await controller.setEnabled(false), isTrue);
            expect(controller.value.enabled, isFalse);
          } else {
            await controller.setTime(hour: 20, minute: 45);
            expect(controller.value.hour, 20);
            expect(controller.value.minute, 45);
          }
        },
      );
    }
  }
}

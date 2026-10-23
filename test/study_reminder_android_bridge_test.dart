// Synthetic owner/settings and a mocked Android method channel only.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.german.ankiReview/studyReminder');
  const platform = MethodChannelStudyReminderPlatform();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({
      'recall_study_reminder_enabled:synthetic-owner': true,
    });
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final permission in <bool?>[true, false, null]) {
    test(
      'Android permission response $permission is interpreted safely',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return permission;
        });
        expect(await platform.requestPermission(), permission == true);
        expect(calls.single.method, 'requestPermission');
        expect(calls.single.arguments, isNull);
      },
    );
  }

  test(
    'Android receives the exact eligibility and local reminder time',
    () async {
      await platform.apply(
        const StudyReminderSettings(enabled: true, hour: 23, minute: 59),
        dueCount: 7,
        studiedToday: false,
      );
      await platform.apply(
        const StudyReminderSettings(enabled: false, hour: 0, minute: 0),
        dueCount: null,
        studiedToday: true,
      );
      expect(calls.map((call) => call.method), ['apply', 'apply']);
      expect(calls.map((call) => call.arguments), [
        {
          'enabled': true,
          'hour': 23,
          'minute': 59,
          'dueCount': 7,
          'studiedToday': false,
        },
        {
          'enabled': false,
          'hour': 0,
          'minute': 0,
          'dueCount': null,
          'studiedToday': true,
        },
      ]);
    },
  );

  test(
    'Android settings recovery and cancellation use their native methods',
    () async {
      await platform.openNotificationSettings();
      await platform.cancel();
      expect(calls.map((call) => call.method), ['openSettings', 'cancel']);
      expect(calls.map((call) => call.arguments), [null, null]);
    },
  );

  test('native failures remain visible to reminder retry logic', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'synthetic_native_failure');
    });
    for (final operation in <Future<void> Function()>[
      () async {
        await platform.requestPermission();
      },
      platform.openNotificationSettings,
      () => platform.apply(
        const StudyReminderSettings(enabled: true, hour: 19, minute: 0),
        dueCount: 7,
        studiedToday: false,
      ),
      platform.cancel,
    ]) {
      await expectLater(
        operation(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'synthetic_native_failure',
          ),
        ),
      );
    }
    expect(calls.map((call) => call.method), [
      'requestPermission',
      'openSettings',
      'apply',
      'cancel',
    ]);
  });

  test(
    'cancelPending preserves the preference and permits identical reapply',
    () async {
      final now = DateTime(2026, 10, 23, 12);
      final controller = StudyReminderController(
        platform: platform,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.initialize(ownerId: 'synthetic-owner');
      await controller.reconcile(
        dueCount: 7,
        lastReviewedAt: null,
        reviewActivityKnown: true,
      );
      calls.clear();

      await controller.cancelPending();
      await controller.reconcile(
        dueCount: 7,
        lastReviewedAt: null,
        reviewActivityKnown: true,
      );

      expect(calls.map((call) => call.method), ['cancel', 'apply']);
      expect(controller.value.enabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('recall_study_reminder_enabled:synthetic-owner'),
        isTrue,
      );
    },
  );

  test(
    'a failed native apply permits retry of identical eligibility',
    () async {
      final now = DateTime(2026, 10, 23, 12);
      final controller = StudyReminderController(
        platform: platform,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      var failApply = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'apply' && failApply) {
          throw PlatformException(code: 'synthetic_native_failure');
        }
        return null;
      });
      await controller.initialize(ownerId: 'synthetic-owner');
      Future<void> reconcile() => controller.reconcile(
        dueCount: 7,
        lastReviewedAt: null,
        reviewActivityKnown: true,
      );

      await expectLater(reconcile(), throwsA(isA<PlatformException>()));
      failApply = false;
      await reconcile();

      expect(calls.map((call) => call.method), ['cancel', 'apply', 'apply']);
      expect(calls[1].arguments, calls[2].arguments);
      expect(controller.value.enabled, isTrue);
    },
  );

  testWidgets(
    'midnight reevaluates yesterday study without a foreground event',
    (tester) async {
      var now = DateTime(2026, 12, 31, 23, 59, 59);
      final controller = StudyReminderController(
        platform: platform,
        clock: () => now,
      );
      try {
        await controller.initialize(ownerId: 'synthetic-owner');
        await controller.reconcile(
          dueCount: 7,
          lastReviewedAt: now,
          reviewActivityKnown: true,
        );
        expect(calls.last.method, 'cancel');
        calls.clear();

        now = DateTime(2027, 1, 1);
        await tester.pump(const Duration(seconds: 1, milliseconds: 1));
        await tester.pump();

        expect(calls.single.method, 'apply');
        expect(calls.single.arguments, {
          'enabled': true,
          'hour': 19,
          'minute': 0,
          'dueCount': 7,
          'studiedToday': false,
        });
        // Signing out must cancel the timer rearmed for the following midnight.
        await controller.releaseOwner();
        now = DateTime(2027, 1, 2);
        await tester.pump(const Duration(days: 1));
        expect(calls.map((call) => call.method), ['apply', 'cancel']);
      } finally {
        controller.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

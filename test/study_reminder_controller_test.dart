import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';

class _FakeStudyReminderPlatform implements StudyReminderPlatform {
  bool permissionGranted = true;
  var permissionRequests = 0;
  final applied = <StudyReminderSettings>[];
  var cancellations = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<void> apply(StudyReminderSettings settings) async =>
      applied.add(settings);

  @override
  Future<void> cancel() async => cancellations++;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('enabling requests permission then persists and schedules', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');

    final enabled = await controller.setEnabled(true);

    expect(enabled, isTrue);
    expect(controller.value.enabled, isTrue);
    expect(platform.permissionRequests, 1);
    expect(platform.applied.last.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('recall_study_reminder_enabled:user-1'), isTrue);
  });

  test('denied permission never stores a misleading enabled state', () async {
    final platform = _FakeStudyReminderPlatform()..permissionGranted = false;
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');

    final enabled = await controller.setEnabled(true);

    expect(enabled, isFalse);
    expect(controller.value.enabled, isFalse);
    expect(platform.applied.last.enabled, isFalse);
  });

  test('time changes reschedule the enabled reminder', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.setEnabled(true);

    await controller.setTime(hour: 20, minute: 45);

    expect(controller.value.hour, 20);
    expect(controller.value.minute, 45);
    expect(platform.applied.last.hour, 20);
    expect(platform.applied.last.minute, 45);
  });

  test(
    'sign-out cancellation keeps the preference for the next sign-in',
    () async {
      final platform = _FakeStudyReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);
      await controller.initialize(ownerId: 'user-1');
      await controller.setEnabled(true);

      await controller.releaseOwner();

      expect(platform.cancellations, 1);
      expect(controller.value.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('recall_study_reminder_enabled:user-1'), isTrue);
    },
  );

  test('switching accounts never reuses another account reminder', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.setEnabled(true);

    await controller.activateOwner('user-2');

    expect(controller.value.enabled, isFalse);
    expect(platform.applied.last.enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('recall_study_reminder_enabled:user-1'), isTrue);
    expect(prefs.getBool('recall_study_reminder_enabled:user-2'), isNull);
  });
}

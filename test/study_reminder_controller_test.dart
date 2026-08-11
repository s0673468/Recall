import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';

class _FakeStudyReminderPlatform implements StudyReminderPlatform {
  bool permissionGranted = true;
  var permissionRequests = 0;
  final applied = <StudyReminderSettings>[];
  final appliedContexts = <({int? dueCount, bool studiedToday})>[];
  var cancellations = 0;
  var settingsOpens = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<void> openNotificationSettings() async => settingsOpens++;

  @override
  Future<void> apply(
    StudyReminderSettings settings, {
    required int? dueCount,
    required bool studiedToday,
  }) async {
    applied.add(settings);
    appliedContexts.add((dueCount: dueCount, studiedToday: studiedToday));
  }

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
    await controller.reconcile(
      dueCount: 3,
      lastReviewedAt: DateTime(2026, 8, 4, 12),
      reviewActivityKnown: true,
    );

    final enabled = await controller.setEnabled(true);

    expect(enabled, isTrue);
    expect(controller.value.enabled, isTrue);
    expect(platform.permissionRequests, 1);
    expect(platform.applied.last.enabled, isTrue);
    expect(platform.appliedContexts.last.dueCount, 3);
    expect(platform.appliedContexts.last.studiedToday, isFalse);
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

  test('notification recovery opens platform settings', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);

    await controller.openNotificationSettings();

    expect(platform.settingsOpens, 1);
  });

  test('time changes reschedule the enabled reminder', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.reconcile(
      dueCount: 3,
      lastReviewedAt: DateTime(2026, 8, 4, 12),
      reviewActivityKnown: true,
    );
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

      final cancellationsBeforeRelease = platform.cancellations;
      await controller.releaseOwner();

      expect(platform.cancellations, cancellationsBeforeRelease + 1);
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
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('recall_study_reminder_enabled:user-1'), isTrue);
    expect(prefs.getBool('recall_study_reminder_enabled:user-2'), isNull);
  });

  test(
    'repeated activation for one account preserves reconciled signals',
    () async {
      final platform = _FakeStudyReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);
      await controller.initialize(ownerId: 'user-1');
      await controller.reconcile(
        dueCount: 3,
        lastReviewedAt: DateTime(2026, 8, 4, 12),
        reviewActivityKnown: true,
      );
      await controller.setEnabled(true);
      final cancellationsBeforeRepeat = platform.cancellations;

      await controller.activateOwner('user-1');
      await controller.reconcile(
        dueCount: 3,
        lastReviewedAt: DateTime(2026, 8, 4, 12),
        reviewActivityKnown: true,
      );

      expect(platform.cancellations, cancellationsBeforeRepeat);
      expect(platform.applied.last.enabled, isTrue);
    },
  );

  test('due zero cancels an already eligible reminder', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.setEnabled(true);
    await controller.reconcile(
      dueCount: 4,
      lastReviewedAt: DateTime(2026, 8, 4, 12),
      reviewActivityKnown: true,
    );
    final cancellationsBeforeZero = platform.cancellations;

    await controller.reconcile(
      dueCount: 0,
      lastReviewedAt: null,
      reviewActivityKnown: true,
    );

    expect(platform.cancellations, cancellationsBeforeZero + 1);
  });

  test('unknown review activity suppresses reminder scheduling', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.setEnabled(true);

    await controller.reconcile(
      dueCount: 4,
      lastReviewedAt: null,
      reviewActivityKnown: false,
    );

    expect(platform.appliedContexts, isEmpty);
  });

  test(
    'studied today suppresses the reminder even when work remains',
    () async {
      final platform = _FakeStudyReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);
      await controller.initialize(ownerId: 'user-1');
      await controller.setEnabled(true);
      final cancellationsBeforeToday = platform.cancellations;

      await controller.reconcile(
        dueCount: 4,
        lastReviewedAt: DateTime.now(),
        reviewActivityKnown: true,
      );

      expect(platform.cancellations, cancellationsBeforeToday + 1);
      expect(platform.appliedContexts, isEmpty);
    },
  );

  test(
    'due work with no review today schedules the one reminder slot',
    () async {
      final platform = _FakeStudyReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);
      await controller.initialize(ownerId: 'user-1');
      await controller.setEnabled(true);

      await controller.reconcile(
        dueCount: 4,
        lastReviewedAt: DateTime.now().subtract(const Duration(days: 1)),
        reviewActivityKnown: true,
      );

      expect(platform.applied.last.enabled, isTrue);
      expect(platform.appliedContexts.last.dueCount, 4);
      expect(platform.appliedContexts.last.studiedToday, isFalse);
    },
  );

  test('time changes reschedule the eligible reminder slot', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.reconcile(
      dueCount: 2,
      lastReviewedAt: DateTime.now().subtract(const Duration(days: 1)),
      reviewActivityKnown: true,
    );
    await controller.setEnabled(true);

    await controller.setTime(hour: 20, minute: 45);

    expect(platform.applied.last.hour, 20);
    expect(platform.applied.last.minute, 45);
    expect(platform.appliedContexts.last.dueCount, 2);
  });

  test('forced reconciliation retries after a permission change', () async {
    final platform = _FakeStudyReminderPlatform();
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);
    await controller.initialize(ownerId: 'user-1');
    await controller.reconcile(
      dueCount: 2,
      lastReviewedAt: DateTime.now().subtract(const Duration(days: 1)),
      reviewActivityKnown: true,
    );
    await controller.setEnabled(true);
    final appliedBeforeForce = platform.applied.length;

    await controller.reconcile(
      dueCount: 2,
      lastReviewedAt: DateTime.now().subtract(const Duration(days: 1)),
      reviewActivityKnown: true,
      force: true,
    );

    expect(platform.applied.length, appliedBeforeForce + 1);
  });
}

import 'dart:async';

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
  Object? cancelError;
  Future<void> Function()? beforeApply;

  int get operationCount =>
      permissionRequests + applied.length + cancellations + settingsOpens;

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
    await beforeApply?.call();
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    final error = cancelError;
    if (error != null) throw error;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'signed-out cold start cancels any stale native reminder once',
    () async {
      final platform = _FakeStudyReminderPlatform();
      final controller = StudyReminderController(platform: platform);
      addTearDown(controller.dispose);

      await controller.initialize(ownerId: null);
      await controller.initialize(ownerId: null);

      expect(platform.cancellations, 1);
      expect(controller.value.enabled, isFalse);
    },
  );

  test('failed signed-out cold-start cancellation remains retryable', () async {
    final platform = _FakeStudyReminderPlatform()
      ..cancelError = StateError('native cancellation failed');
    final controller = StudyReminderController(platform: platform);
    addTearDown(controller.dispose);

    await expectLater(controller.initialize(ownerId: null), throwsStateError);
    platform.cancelError = null;
    await controller.initialize(ownerId: null);

    expect(platform.cancellations, 2);
  });

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

  for (final changingSettings in [false, true]) {
    testWidgets(
      'disposal during ${changingSettings ? 'a settings save' : 'reconciliation'} '
      'drops queued work and midnight timers',
      (tester) async {
        final timers = <Timer>[];
        await runZoned(
          () async {
            SharedPreferences.setMockInitialValues({
              'recall_study_reminder_enabled:user-1': true,
            });
            var now = DateTime(2026, 10, 25, 23, 59, 59);
            final platform = _FakeStudyReminderPlatform();
            final controller = StudyReminderController(
              platform: platform,
              clock: () => now,
            );
            addTearDown(controller.dispose);
            await controller.initialize(ownerId: 'user-1');
            await controller.reconcile(
              dueCount: 3,
              lastReviewedAt: null,
              reviewActivityKnown: true,
            );
            expect(timers.where((timer) => timer.isActive), hasLength(1));

            final applyStarted = Completer<void>();
            final finishApply = Completer<void>();
            platform.beforeApply = () {
              applyStarted.complete();
              return finishApply.future;
            };
            final inFlight = changingSettings
                ? controller.setTime(hour: 20, minute: 45)
                : controller.reconcile(
                    dueCount: 3,
                    lastReviewedAt: null,
                    reviewActivityKnown: true,
                    force: true,
                  );
            await applyStarted.future;
            final queuedCancellation = controller.reconcile(
              dueCount: 0,
              lastReviewedAt: null,
              reviewActivityKnown: true,
              force: true,
            );
            final queuedApply = controller.reconcile(
              dueCount: 7,
              lastReviewedAt: null,
              reviewActivityKnown: true,
              force: true,
            );
            final operationsAtDisposal = platform.operationCount;

            controller.dispose();
            expect(controller.dispose, returnsNormally);
            expect(timers.where((timer) => timer.isActive), isEmpty);
            finishApply.complete();
            await Future.wait([inFlight, queuedCancellation, queuedApply]);

            expect(platform.operationCount, operationsAtDisposal);
            expect(timers.where((timer) => timer.isActive), isEmpty);
            if (changingSettings) {
              // A successful apply still finishes its existing save contract.
              expect(controller.value.hour, 20);
              expect(controller.value.minute, 45);
              final prefs = await SharedPreferences.getInstance();
              expect(prefs.getInt('recall_study_reminder_hour:user-1'), 20);
              expect(prefs.getInt('recall_study_reminder_minute:user-1'), 45);
            }

            await controller.reconcile(
              dueCount: 9,
              lastReviewedAt: null,
              reviewActivityKnown: true,
              force: true,
            );
            for (final day in [26, 27]) {
              final next = DateTime(2026, 10, day, 0, 0, 0, 1);
              final elapsed = next.difference(now);
              now = next;
              await tester.pump(elapsed);
              expect(platform.operationCount, operationsAtDisposal);
              expect(timers.where((timer) => timer.isActive), isEmpty);
            }
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              final timer = parent.createTimer(zone, duration, callback);
              timers.add(timer);
              return timer;
            },
          ),
        );
      },
    );
  }
}

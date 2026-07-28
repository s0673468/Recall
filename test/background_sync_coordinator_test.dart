import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/background/background_sync_coordinator.dart';
import 'package:health_anki_flutter/core/diagnostics/operational_diagnostics.dart';

class _FakeBackgroundSyncPlatform implements BackgroundSyncPlatform {
  Future<String> Function()? handler;
  var starts = 0;

  @override
  Future<void> start(Future<String> Function() onSyncRequested) async {
    starts++;
    handler = onSyncRequested;
  }
}

class _RecordingDiagnostics implements OperationalEventRecorder {
  final events =
      <
        ({
          OperationalComponent component,
          OperationalOperation operation,
          OperationalOutcome outcome,
          OperationalCauseCode causeCode,
          bool retryable,
        })
      >[];

  @override
  Future<void> record({
    required OperationalLevel level,
    required OperationalComponent component,
    required OperationalOperation operation,
    required OperationalOutcome outcome,
    required OperationalCauseCode causeCode,
    required bool retryable,
    int? exitCode,
    int? durationMs,
  }) async {
    events.add((
      component: component,
      operation: operation,
      outcome: outcome,
      causeCode: causeCode,
      retryable: retryable,
    ));
  }
}

class _DelayedDiagnostics implements OperationalEventRecorder {
  final persisted = Completer<void>();

  @override
  Future<void> record({
    required OperationalLevel level,
    required OperationalComponent component,
    required OperationalOperation operation,
    required OperationalOutcome outcome,
    required OperationalCauseCode causeCode,
    required bool retryable,
    int? exitCode,
    int? durationMs,
  }) => persisted.future;
}

void main() {
  test('background sync reports new data when durable writes drain', () async {
    final platform = _FakeBackgroundSyncPlatform();
    final coordinator = BackgroundSyncCoordinator(
      platform: platform,
      sync: () async =>
          const BackgroundSyncReport(attempted: 3, delivered: 2, pending: 1),
    );

    await coordinator.start();

    expect(platform.starts, 1);
    expect(await platform.handler!(), 'newData');
  });

  test(
    'background sync reports no data when there was nothing queued',
    () async {
      final platform = _FakeBackgroundSyncPlatform();
      final coordinator = BackgroundSyncCoordinator(
        platform: platform,
        sync: () async =>
            const BackgroundSyncReport(attempted: 0, delivered: 0, pending: 0),
      );

      await coordinator.start();

      expect(await platform.handler!(), 'noData');
    },
  );

  test(
    'background sync reports failure without dropping pending writes',
    () async {
      final platform = _FakeBackgroundSyncPlatform();
      final coordinator = BackgroundSyncCoordinator(
        platform: platform,
        sync: () async =>
            const BackgroundSyncReport(attempted: 2, delivered: 0, pending: 2),
      );

      await coordinator.start();

      expect(await platform.handler!(), 'failed');
    },
  );

  test('background callback exceptions are contained and diagnosed', () async {
    final platform = _FakeBackgroundSyncPlatform();
    final diagnostics = _RecordingDiagnostics();
    final coordinator = BackgroundSyncCoordinator(
      platform: platform,
      diagnostics: diagnostics,
      sync: () async =>
          throw StateError('private card and endpoint must never be logged'),
    );

    await coordinator.start();

    expect(await platform.handler!(), 'failed');
    expect(diagnostics.events, [
      (
        component: OperationalComponent.backgroundSync,
        operation: OperationalOperation.syncPending,
        outcome: OperationalOutcome.failed,
        causeCode: OperationalCauseCode.backgroundSyncFailed,
        retryable: true,
      ),
    ]);
  });

  test('background failure waits for diagnostic persistence', () async {
    final platform = _FakeBackgroundSyncPlatform();
    final diagnostics = _DelayedDiagnostics();
    final coordinator = BackgroundSyncCoordinator(
      platform: platform,
      diagnostics: diagnostics,
      sync: () async => throw StateError('private failure'),
    );
    await coordinator.start();

    var completed = false;
    final result = platform.handler!().then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    diagnostics.persisted.complete();
    expect(await result, 'failed');
  });
}

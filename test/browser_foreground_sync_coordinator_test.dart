import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/background/browser_foreground_sync_coordinator.dart';
import 'package:health_anki_flutter/core/background/browser_sync_platform.dart';
import 'package:health_anki_flutter/core/diagnostics/operational_diagnostics.dart';

class _Browser implements BrowserSyncPlatform {
  @override
  bool supported = true;
  @override
  bool visible = true;
  @override
  bool online = true;
  int starts = 0;
  int disposals = 0;
  void Function()? wake;

  @override
  void start(void Function() onWake) {
    starts++;
    wake = onWake;
  }

  @override
  void dispose() {
    disposals++;
    wake = null;
  }
}

class _Diagnostics implements OperationalEventRecorder {
  final causes = <OperationalCauseCode>[];
  bool fail = false;

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
    causes.add(causeCode);
    if (fail) throw StateError('diagnostics unavailable');
  }
}

void main() {
  testWidgets(
    'online wake retries immediately and idle refresh follows replay',
    (tester) async {
      final browser = _Browser()..online = false;
      final calls = <String>[];
      final coordinator = BrowserForegroundSyncCoordinator(
        platform: browser,
        hasSession: () => true,
        syncPending: () async =>
            calls.add('replay reviews, flags, preferences'),
        refreshIfIdle: () async => calls.add('refresh'),
      )..start();
      addTearDown(coordinator.dispose);

      await tester.pump(const Duration(minutes: 2));
      expect(calls, isEmpty);
      browser.online = true;
      browser.wake!();
      await tester.pump();
      expect(calls, ['replay reviews, flags, preferences', 'refresh']);
      coordinator.dispose();
    },
  );

  testWidgets('visible open tab catches up at bounded interval', (
    tester,
  ) async {
    final browser = _Browser();
    var syncs = 0;
    final coordinator = BrowserForegroundSyncCoordinator(
      platform: browser,
      hasSession: () => true,
      syncPending: () async => syncs++,
      refreshIfIdle: () async {},
    )..start();
    addTearDown(coordinator.dispose);

    await tester.pump(const Duration(seconds: 59));
    expect(syncs, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(syncs, 1);
    browser.visible = false;
    browser.wake!();
    await tester.pump(const Duration(minutes: 3));
    expect(syncs, 1);
    browser.visible = true;
    browser.wake!();
    await tester.pump();
    expect(syncs, 2);
    coordinator.dispose();
  });

  testWidgets('signed-out and native surfaces never request cloud sync', (
    tester,
  ) async {
    final browser = _Browser();
    var signedIn = false;
    var syncs = 0;
    final coordinator = BrowserForegroundSyncCoordinator(
      platform: browser,
      hasSession: () => signedIn,
      syncPending: () async => syncs++,
      refreshIfIdle: () async {},
    )..start();
    addTearDown(coordinator.dispose);
    browser.wake!();
    await tester.pump(const Duration(minutes: 1));
    expect(syncs, 0);
    signedIn = true;
    browser.wake!();
    await tester.pump();
    expect(syncs, 1);

    final native = _Browser()..supported = false;
    final nativeCoordinator = BrowserForegroundSyncCoordinator(
      platform: native,
      hasSession: () => true,
      syncPending: () async => syncs++,
      refreshIfIdle: () async {},
    )..start();
    addTearDown(nativeCoordinator.dispose);
    await nativeCoordinator.sync();
    expect(native.starts, 0);
    expect(syncs, 1);
    expect(createBrowserSyncPlatform().supported, isFalse);
    coordinator.dispose();
    nativeCoordinator.dispose();
  });

  testWidgets('wake storms serialize one follow-up behind in-flight writes', (
    tester,
  ) async {
    final browser = _Browser();
    final held = Completer<void>();
    final calls = <String>[];
    var syncs = 0;
    final coordinator = BrowserForegroundSyncCoordinator(
      platform: browser,
      hasSession: () => true,
      syncPending: () async {
        syncs++;
        calls.add('sync $syncs');
        if (syncs == 1) await held.future;
      },
      refreshIfIdle: () async => calls.add('refresh'),
    )..start();
    addTearDown(coordinator.dispose);
    coordinator.start();
    final first = coordinator.sync();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      browser.wake!();
    }
    await tester.pump(const Duration(minutes: 1));
    expect(syncs, 1);
    held.complete();
    await tester.pump();
    await first;
    expect(calls, ['sync 1', 'refresh', 'sync 2', 'refresh']);
    expect(browser.starts, 1);
    coordinator.dispose();
  });

  testWidgets(
    'dispose stops timer, event signals and in-flight follow-up reads',
    (tester) async {
      final browser = _Browser();
      final held = Completer<void>();
      var syncs = 0;
      var refreshes = 0;
      final coordinator = BrowserForegroundSyncCoordinator(
        platform: browser,
        hasSession: () => true,
        syncPending: () async {
          syncs++;
          await held.future;
        },
        refreshIfIdle: () async => refreshes++,
      )..start();
      final capturedWake = browser.wake!;
      final running = coordinator.sync();
      await tester.pump();
      capturedWake();
      coordinator.dispose();
      coordinator.dispose();
      held.complete();
      await tester.pump();
      await running;
      capturedWake();
      await tester.pump(const Duration(minutes: 3));
      expect(syncs, 1);
      expect(refreshes, 0);
      expect(browser.wake, isNull);
      expect(browser.disposals, 1);
    },
  );

  testWidgets(
    'session loss or hidden tab during replay blocks the cloud read',
    (tester) async {
      for (final signOut in [false, true]) {
        final browser = _Browser();
        var signedIn = true;
        var refreshes = 0;
        final held = Completer<void>();
        final coordinator = BrowserForegroundSyncCoordinator(
          platform: browser,
          hasSession: () => signedIn,
          syncPending: () => held.future,
          refreshIfIdle: () async => refreshes++,
        )..start();
        final running = coordinator.sync();
        await tester.pump();
        if (signOut) {
          signedIn = false;
        } else {
          browser.visible = false;
        }
        held.complete();
        await tester.pump();
        await running;
        expect(refreshes, 0);
        coordinator.dispose();
      }
    },
  );

  testWidgets('failed replay is diagnosed safely and next wake recovers', (
    tester,
  ) async {
    final browser = _Browser();
    final diagnostics = _Diagnostics()..fail = true;
    var fail = true;
    var refreshes = 0;
    final coordinator = BrowserForegroundSyncCoordinator(
      platform: browser,
      hasSession: () => true,
      diagnostics: diagnostics,
      syncPending: () async {
        if (fail) throw StateError('private content must not be logged');
      },
      refreshIfIdle: () async => refreshes++,
    )..start();
    addTearDown(coordinator.dispose);
    await coordinator.sync();
    expect(diagnostics.causes, [OperationalCauseCode.foregroundSyncFailed]);
    expect(refreshes, 0);
    fail = false;
    browser.wake!();
    await tester.pump();
    expect(refreshes, 1);
    coordinator.dispose();
  });
}

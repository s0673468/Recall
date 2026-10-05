import 'dart:async';

import '../diagnostics/operational_diagnostics.dart';
import 'browser_sync_platform.dart';

/// Keeps an open website caught up using the controller's existing durable
/// write replay, then its active-card-safe idle refresh. Hidden/offline tabs
/// and signed-out sessions make no periodic network requests.
class BrowserForegroundSyncCoordinator {
  final BrowserSyncPlatform platform;
  final bool Function() hasSession;
  final Future<void> Function() syncPending;
  final Future<void> Function() refreshIfIdle;
  final Duration interval;
  final OperationalEventRecorder diagnostics;

  Timer? _timer;
  Future<void>? _running;
  bool _followUp = false;
  bool _started = false;
  bool _disposed = false;

  BrowserForegroundSyncCoordinator({
    required this.platform,
    required this.hasSession,
    required this.syncPending,
    required this.refreshIfIdle,
    this.interval = const Duration(minutes: 1),
    OperationalEventRecorder? diagnostics,
  }) : assert(interval > Duration.zero),
       diagnostics = diagnostics ?? RecallDiagnostics.instance;

  void start() {
    if (_started || _disposed || !platform.supported) return;
    _started = true;
    platform.start(_wake);
    _timer = Timer.periodic(interval, (_) => _wake());
  }

  bool get _canSync =>
      _started &&
      !_disposed &&
      platform.visible &&
      platform.online &&
      hasSession();

  void _wake() => unawaited(sync());

  /// Also used by Flutter's foreground lifecycle callback so browser wake
  /// signals share one serialized path. At most one extra pass is queued.
  Future<void> sync() {
    if (!_canSync) return Future<void>.value();
    final running = _running;
    if (running != null) {
      _followUp = true;
      return running;
    }
    final task = _run().whenComplete(() => _running = null);
    _running = task;
    return task;
  }

  Future<void> _run() async {
    do {
      _followUp = false;
      try {
        // This also replays/refreshes account-scoped study preferences. Its
        // review and flag loops retain their own existing single-flight locks.
        await syncPending();
        if (_canSync) await refreshIfIdle();
      } catch (_) {
        try {
          await diagnostics.record(
            level: OperationalLevel.error,
            component: OperationalComponent.foregroundSync,
            operation: OperationalOperation.syncPending,
            outcome: OperationalOutcome.failed,
            causeCode: OperationalCauseCode.foregroundSyncFailed,
            retryable: true,
          );
        } catch (_) {
          // Diagnostics must not turn an event/timer callback into an
          // unhandled asynchronous error. Never log raw failure values.
        }
      }
    } while (_followUp && _canSync);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _followUp = false;
    _timer?.cancel();
    platform.dispose();
  }
}

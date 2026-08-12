import 'dart:async';

import 'package:flutter/foundation.dart';

import 'operational_diagnostics.dart';

void installRecallErrorHandlers(OperationalEventRecorder diagnostics) {
  FlutterError.onError = (details) {
    recordFlutterFrameworkError(
      diagnostics,
      details.exception,
      details.stack ?? StackTrace.empty,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) =>
      recordUncaughtPlatformError(diagnostics, error, stack);
}

@visibleForTesting
void recordFlutterFrameworkError(
  OperationalEventRecorder diagnostics,
  Object _,
  StackTrace _,
) {
  unawaited(
    diagnostics.record(
      level: OperationalLevel.error,
      component: OperationalComponent.framework,
      operation: OperationalOperation.handleFrameworkError,
      outcome: OperationalOutcome.failed,
      causeCode: OperationalCauseCode.flutterFrameworkError,
      retryable: false,
    ),
  );
}

@visibleForTesting
bool recordUncaughtPlatformError(
  OperationalEventRecorder diagnostics,
  Object _,
  StackTrace _,
) {
  unawaited(
    diagnostics.record(
      level: OperationalLevel.error,
      component: OperationalComponent.framework,
      operation: OperationalOperation.handleUncaughtError,
      outcome: OperationalOutcome.failed,
      causeCode: OperationalCauseCode.flutterUncaughtError,
      retryable: false,
    ),
  );
  // OperationalDiagnostics emits the allowlisted console event synchronously
  // before its best-effort preference write. Mark the error handled so the
  // embedder cannot fall back to printing the discarded exception or stack.
  return true;
}

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'operational_diagnostics.dart';

/// Mirrors Recall's already-sanitized diagnostic ring to an iOS app-container
/// file that a trusted host can copy without opening SharedPreferences.
///
/// The native writer independently validates the same closed envelope. Calls
/// are best-effort: a missing channel or failed write never changes app flow.
final class MethodChannelOperationalEventExporter
    implements OperationalEventExporter {
  static const channel = MethodChannel(
    'com.german.ankiReview/operationalDiagnostics',
  );

  const MethodChannelOperationalEventExporter();

  @override
  Future<void> export(String encoded) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!isCanonicalOperationalEventPayload(encoded)) return;
    try {
      await channel.invokeMethod<void>('mirror', {'payload': encoded});
    } catch (_) {
      // The mirror is diagnostics-only and must never affect Recall behavior.
    }
  }
}

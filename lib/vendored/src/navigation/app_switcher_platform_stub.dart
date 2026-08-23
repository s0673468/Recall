import 'package:url_launcher/url_launcher.dart';

/// Native Recall opens the deployed app family. Start from the standalone
/// Recall site; Track itself is preferred via `track://today`, with HTTPS used
/// only when TRACK_WEB_ROOT or HEALTH_SUITE_ROOT was explicitly configured.
String? documentBaseUri() => const String.fromEnvironment(
  'RECALL_WEB_ROOT',
  defaultValue: 'https://s0673468.github.io/Recall/',
);

typedef NativeUrlLauncher = Future<bool> Function(Uri uri);

Future<void> assignLocation(
  String? fallbackUrl, {
  String? preferredNativeUrl,
  NativeUrlLauncher? launcher,
}) async {
  final open =
      launcher ??
      (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
  if (preferredNativeUrl != null) {
    try {
      if (await open(Uri.parse(preferredNativeUrl))) return;
    } catch (_) {
      // A missing app/scheme is expected; continue to an explicit web fallback.
    }
  }
  if (fallbackUrl == null) return;
  final fallback = Uri.tryParse(fallbackUrl);
  if (fallback != null &&
      fallback.scheme == 'https' &&
      fallback.host.isNotEmpty) {
    await open(fallback);
  }
}

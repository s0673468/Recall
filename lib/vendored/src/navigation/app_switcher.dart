import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/shared_ui_tokens.dart';
import 'app_switcher_platform_stub.dart'
    if (dart.library.js_interop) 'app_switcher_platform_web.dart'
    as platform;

const _configuredHealthSuiteRoot = String.fromEnvironment('HEALTH_SUITE_ROOT');
const _configuredTrackWebRoot = String.fromEnvironment('TRACK_WEB_ROOT');
const _configuredRecallWebRoot = String.fromEnvironment('RECALL_WEB_ROOT');

/// One installable app in the Health family.
///
/// Track and Recall are the two maintained products. Recall is deployed from
/// its standalone repository. Track's public web route is optional because a
/// private Pages deployment can return 404 to an unauthenticated browser.
class HealthWebApp {
  /// Home-screen name of the app (matches each manifest's `short_name`).
  final String name;

  final IconData icon;

  /// Installed-app deep link preferred by native mobile.
  final String? preferredNativeUri;

  const HealthWebApp._(this.name, this.icon, {this.preferredNativeUri});

  static const track = HealthWebApp._(
    'Track',
    Icons.checklist_rounded,
    preferredNativeUri: 'track://today',
  );
  static const recall = HealthWebApp._('Recall', Icons.style_rounded);

  /// Every maintained app in display order.
  static const List<HealthWebApp> all = [track, recall];
}

/// Resolve an app-family destination from Recall's current document base.
///
/// Recall defaults to its real public Pages path. Track gets an HTTPS route
/// only when TRACK_WEB_ROOT (preferred) or the legacy HEALTH_SUITE_ROOT is
/// explicitly configured; otherwise the public PWA hides the one-app switcher
/// and native mobile uses Track's installed-app URI without a dead web link.
@visibleForTesting
String? appDestinationFromBaseUri(
  HealthWebApp app,
  String? baseUri, {
  String? healthSuiteRoot,
  String? trackWebRoot,
  String? recallWebRoot,
}) {
  final current = baseUri == null ? null : Uri.tryParse(baseUri);
  if (current == null || !current.hasScheme || current.host.isEmpty) {
    return null;
  }

  final origin = current.replace(path: '/', query: null, fragment: null);
  if (app == HealthWebApp.track) {
    final track = trackWebRoot ?? _configuredTrackWebRoot;
    if (track.isNotEmpty) {
      return _httpsDirectoryUri(track, relativeTo: origin)?.toString();
    }
    final health = healthSuiteRoot ?? _configuredHealthSuiteRoot;
    final healthRoot = _httpsDirectoryUri(health, relativeTo: origin);
    return healthRoot?.resolve('track/').toString();
  }
  return _directoryUri(
    recallWebRoot ?? _configuredRecallWebRoot,
    fallback: origin.resolve('Recall/'),
    relativeTo: origin,
  )?.toString();
}

Uri? _directoryUri(
  String configured, {
  Uri? fallback,
  required Uri relativeTo,
}) {
  if (configured.isEmpty) return fallback;
  final parsed = Uri.tryParse(configured);
  if (parsed == null) return fallback;
  final absolute = parsed.hasScheme ? parsed : relativeTo.resolveUri(parsed);
  final path = absolute.path.endsWith('/')
      ? absolute.path
      : '${absolute.path}/';
  return absolute.replace(path: path, query: null, fragment: null);
}

Uri? _httpsDirectoryUri(String configured, {required Uri relativeTo}) {
  final uri = _directoryUri(configured, relativeTo: relativeTo);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
      ? uri
      : null;
}

void _openApp(HealthWebApp app) {
  final destination = appDestinationFromBaseUri(
    app,
    platform.documentBaseUri(),
  );
  // Same-tab assign: keeps a standalone iPhone PWA in-place instead of
  // popping the target app out into a browser tab.
  unawaited(
    platform.assignLocation(
      destination,
      preferredNativeUrl: app.preferredNativeUri,
    ),
  );
}

/// A compact pill row linking the active Health apps, highlighting [current].
/// Configured browser builds navigate in-place. Native mobile prefers installed
/// app links and opens an explicitly configured web fallback when unavailable.
/// Other native platforms render nothing.
class AppSwitcher extends StatelessWidget {
  final HealthWebApp current;
  final WrapAlignment alignment;

  const AppSwitcher({
    super.key,
    required this.current,
    this.alignment = WrapAlignment.start,
  });

  /// Whether the switcher renders at all on this platform. Use this to hide
  /// surrounding chrome (section cards, headers) on non-web builds.
  static bool get isSupported => supportsAppSwitcher();

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: UiSpacing.xs,
      runSpacing: UiSpacing.xs,
      alignment: alignment,
      children: [
        for (final app in HealthWebApp.all)
          _AppPill(app: app, selected: app == current, accent: accent),
      ],
    );
  }
}

class _AppPill extends StatelessWidget {
  final HealthWebApp app;
  final bool selected;
  final Color accent;

  const _AppPill({
    required this.app,
    required this.selected,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? accent : UiColors.textSecondary;
    return Material(
      color: selected ? accent.withValues(alpha: 0.15) : UiColors.secondary,
      borderRadius: BorderRadius.circular(UiRadii.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(UiRadii.pill),
        key: Key('app_switcher_${app.name.toLowerCase()}'),
        onTap: selected ? null : () => _openApp(app),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(
            horizontal: UiSpacing.sm,
            vertical: UiSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(app.icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                app.name,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// App-bar variant of [AppSwitcher]: a single icon button opening a menu of
/// the active apps, for apps whose chrome has no settings surface to host the
/// pill row. Supported on web and native mobile.
class AppSwitcherMenuButton extends StatelessWidget {
  final HealthWebApp current;

  const AppSwitcherMenuButton({super.key, required this.current});

  @override
  Widget build(BuildContext context) {
    if (!AppSwitcher.isSupported) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return PopupMenuButton<HealthWebApp>(
      tooltip: 'Switch app',
      icon: const Icon(Icons.apps_rounded),
      onSelected: _openApp,
      itemBuilder: (context) => [
        for (final app in HealthWebApp.all)
          PopupMenuItem(
            value: app,
            enabled: app != current,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  app.icon,
                  size: 18,
                  color: app == current ? accent : UiColors.textSecondary,
                ),
                const SizedBox(width: UiSpacing.xs),
                Text(app.name),
                if (app == current) ...[
                  const SizedBox(width: UiSpacing.xs),
                  Icon(Icons.check_rounded, size: 16, color: accent),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

@visibleForTesting
bool supportsAppSwitcher({
  bool? isWeb,
  TargetPlatform? targetPlatform,
  bool? hasWebSibling,
}) {
  if (isWeb ?? kIsWeb) {
    return hasWebSibling ??
        (_configuredTrackWebRoot.isNotEmpty ||
            _configuredHealthSuiteRoot.isNotEmpty);
  }
  return switch (targetPlatform ?? defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => true,
    _ => false,
  };
}

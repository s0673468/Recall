import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/shared_ui_tokens.dart';
import 'app_switcher_platform_stub.dart'
    if (dart.library.js_interop) 'app_switcher_platform_web.dart'
    as platform;

/// One installable app of the Health suite. The web apps are served from the
/// same origin under one suite root (e.g. `https://<host>/Health/`), each at
/// its own subpath.
class HealthWebApp {
  /// Home-screen name of the app (matches each manifest's `short_name`).
  final String name;

  /// Subpath under the suite root: `''` for the dashboard, `'track/'`, ...
  final String subpath;

  final IconData icon;

  const HealthWebApp._(this.name, this.subpath, this.icon);

  static const dashboard = HealthWebApp._(
    'Dashboard',
    '',
    Icons.monitor_heart_rounded,
  );
  static const track = HealthWebApp._(
    'Track',
    'track/',
    Icons.checklist_rounded,
  );
  static const recall = HealthWebApp._(
    'Recall',
    'recall/',
    Icons.style_rounded,
  );

  /// Every app in the suite, in switcher display order.
  static const List<HealthWebApp> all = [dashboard, track, recall];
}

/// Resolves the suite root from a document base URI by stripping a trailing
/// sub-app segment (`track/`, `recall/`). The dashboard's base *is*
/// the root. Works on any host because nothing about the origin or the
/// `/Health/` prefix is hardcoded — Flutter's injected `<base href>` already
/// encodes the deployed path.
///
/// On native iOS, the platform adapter supplies the configured deployed suite
/// root instead of a document URI.
@visibleForTesting
String? suiteRootFromBaseUri(String? baseUri) {
  if (baseUri == null || baseUri.isEmpty) return null;
  var base = baseUri;
  for (final separator in const ['?', '#']) {
    final index = base.indexOf(separator);
    if (index >= 0) base = base.substring(0, index);
  }
  if (!base.endsWith('/')) {
    // Drop a trailing document name (e.g. `.../index.html`).
    final slash = base.lastIndexOf('/');
    if (slash < 0) return null;
    base = base.substring(0, slash + 1);
  }
  for (final app in HealthWebApp.all) {
    final sub = app.subpath;
    if (sub.isNotEmpty && base.endsWith('/$sub')) {
      return base.substring(0, base.length - sub.length);
    }
  }
  return base;
}

void _openApp(HealthWebApp app) {
  final root = suiteRootFromBaseUri(platform.documentBaseUri());
  if (root == null) return;
  // Same-tab assign: keeps a standalone iPhone PWA in-place instead of
  // popping the target app out into a browser tab.
  unawaited(platform.assignLocation('$root${app.subpath}'));
}

/// A compact pill row linking the active Health apps, highlighting [current].
/// Browser builds stay in the suite; native iOS opens sibling apps in Safari.
/// Other native platforms render nothing, so callers can drop it in unguarded.
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
  static bool get isSupported =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.iOS;

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
/// pill row. Supported on web and native iOS.
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

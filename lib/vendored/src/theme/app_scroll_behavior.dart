import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Scroll behavior for the Flutter web apps.
///
/// Adds trackpad-drag scrolling on top of the Material defaults and swaps the
/// default chunky overlay scrollbar for a thin, rounded one that fades in while
/// scrolling. Mouse drag is deliberately not enabled: charts use mouse drag and
/// hover for their tooltips, and stealing it for scroll would break them.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: false,
      thickness: 6,
      radius: const Radius.circular(8),
      child: child,
    );
  }
}

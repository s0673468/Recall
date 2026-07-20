import 'package:flutter/material.dart';

import '../../theme/shared_ui_tokens.dart';

/// A faint atmospheric texture painted behind a card's content — a
/// print-through-terminal look at whisper volume. Deterministic,
/// non-interactive, and cheap (single-pass painter). Inert today: no live
/// [MoodScope] provider remains, so this is retained shared infrastructure.
///
/// Two intensities:
///  * hero (`ambient: false`): sun-glow radial + halftone dot grid +
///    scanlines — the full weather, for the day-carrying cards.
///  * ambient (`ambient: true`): scanlines only, even fainter — the texture
///    every standard card wears inside a [MoodScope].
class MoodAtmosphere extends StatelessWidget {
  final UiMood mood;

  /// Render the faint ambient tier instead of the full hero atmosphere.
  final bool ambient;

  const MoodAtmosphere({super.key, required this.mood, this.ambient = false});

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary + isComplex: the texture is static for a given mood but
    // draws thousands of primitives; isolating it in its own cached layer
    // stops every card-content repaint (chart hover/scroll) from
    // re-rasterizing the whole grid — a real cost on iOS Safari's CanvasKit.
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(UiRadii.card),
          child: CustomPaint(
            painter: _MoodAtmospherePainter(mood, ambient: ambient),
            isComplex: true,
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

/// Provides a day's mood to every descendant [SectionCard]: cards
/// inside the scope wear the faint ambient wash + scanlines automatically,
/// while the one or two `hero: true` cards render the full weather. No scope
/// (mood unknown, weekly pack unavailable) → plain panels everywhere.
class MoodScope extends InheritedWidget {
  final UiMood? mood;

  const MoodScope({super.key, required this.mood, required super.child});

  static UiMood? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoodScope>()?.mood;

  @override
  bool updateShouldNotify(MoodScope oldWidget) => oldWidget.mood != mood;
}

/// Decoration for local/legacy panel widgets that don't use [SectionCard]:
/// the ambient mood wash when inside a [MoodScope], the plain panel
/// otherwise. Lets satellite apps' bespoke panels join the weather without
/// adopting the shared card.
BoxDecoration scopedPanelDecoration(BuildContext context, {Color? tint}) {
  final mood = tint == null ? MoodScope.of(context) : null;
  if (mood == null) return buildPanelDecoration(tint: tint);
  return buildAmbientPanelDecoration(mood);
}

/// Flat panel colour with the ambient mood blended in — for surfaces that
/// take a single colour (Material fills, small chips) rather than a full
/// decoration.
Color scopedPanelColor(BuildContext context) {
  final mood = MoodScope.of(context);
  if (mood == null) return UiColors.panel;
  return Color.lerp(UiColors.panel, mood.deep, 0.18)!;
}

class _MoodAtmospherePainter extends CustomPainter {
  final UiMood mood;
  final bool ambient;

  const _MoodAtmospherePainter(this.mood, {required this.ambient});

  @override
  void paint(Canvas canvas, Size size) {
    if (!ambient) {
      // Sun glow: high in the card's top-right, like the film's disc.
      final center = Offset(size.width * 0.82, size.height * 0.10);
      final radius = size.shortestSide * 0.9;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              mood.sun.withValues(alpha: 0.10),
              mood.sun.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );

      // Halftone dot grid at ~2% — visible as texture, invisible as pattern.
      final dot = Paint()..color = Colors.white.withValues(alpha: 0.02);
      const spacing = 7.0;
      for (var y = spacing / 2; y < size.height; y += spacing) {
        final shift = ((y ~/ spacing).isEven) ? 0.0 : spacing / 2;
        for (var x = spacing / 2 + shift; x < size.width; x += spacing) {
          canvas.drawCircle(Offset(x, y), 0.6, dot);
        }
      }
    }

    // Scanlines — the film's print screen, one hairline every 3px.
    final scan = Paint()
      ..color = Colors.white.withValues(alpha: ambient ? 0.010 : 0.015)
      ..strokeWidth = 1;
    for (var y = 1.5; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), scan);
    }
  }

  @override
  bool shouldRepaint(_MoodAtmospherePainter oldDelegate) =>
      oldDelegate.mood != mood || oldDelegate.ambient != ambient;
}

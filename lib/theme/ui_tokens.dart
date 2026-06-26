import 'package:flutter/material.dart';
import 'package:health_flutter_shared/ui_tokens_canonical.dart' hide UiColors;

/// Recall reuses the Health design system verbatim — Outfit + DM Sans, the dark
/// navy-violet surfaces, indigo accent, and the iOS frosted chrome. Only the
/// brand name and the accent split are app-local (mirrors how mobile/Lift do it).
export 'package:health_flutter_shared/ui_tokens_canonical.dart'
    show
        UiSpacing,
        UiRadii,
        UiRadius,
        UiTypography,
        UiLayout,
        UiIos,
        scaffoldGradient,
        buildPanelDecoration,
        buildGlassDecoration,
        glassSpecularGradient,
        buildHealthTheme;

abstract final class UiBrand {
  static const appName = 'Recall';
  static const subtitle = 'Spaced repetition';
}

/// Indigo accent, same as mobile + Lift — keeps the app family consistent.
abstract final class UiColors {
  static const canvas = Color(0xFF1B1B29);
  static const sidebar = Color(0xFF202030);
  static const panel = Color(0xFF252540);
  static const panelRaised = Color(0xFF181824);
  static const border = Color(0xFF33345A);
  static const borderSubtle = Color(0x4D33345A);
  static const textPrimary = Color(0xFFF0F0F5);
  static const textSecondary = Color(0xFFA0A8BD);
  static const textMuted = Color(0xFF95919E);
  static const primary = Color(0xFF7F85FF);
  static const primaryMuted = Color(0x267F85FF);
  static const secondary = Color(0xFF2D2D44);
  static const chartYellow = Color(0xFFFDE047);
  static const chartBlue = Color(0xFF5B8FF9);
  static const chartPurple = Color(0xFF8B5CF6);
  static const chartTeal = Color(0xFF2DD4BF);
  static const chartOrange = Color(0xFFFB923C);
  static const success = chartTeal;
  static const warning = chartYellow;
  static const danger = chartOrange;
  static const info = chartBlue;
  static const glassFill = Color(0x8C1C1C2E);
  static const glassHairline = Color(0x1AFFFFFF);
  // iOS chrome tints (mirrors canonical names the shared widgets read).
  static const tintApp = primary;
  static const tintAppMuted = primaryMuted;
}

/// The Recall Material theme — the shared factory with the indigo accent.
ThemeData buildRecallTheme() => buildHealthTheme(
  accent: UiColors.primary,
  accentMuted: UiColors.primaryMuted,
);

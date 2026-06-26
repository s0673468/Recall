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

/// Colour literals mirror the canonical [UiColors] exactly — parity is enforced
/// by `scripts/check_docs_drift.py` and `test/token_parity_test.dart`. Recall's
/// accent is indigo (same family as mobile + Lift); only `primary` /
/// `primaryMuted` differ from the canonical emerald.
abstract final class UiColors {
  static const canvas = Color(0xFF1B1B29);
  static const sidebar = Color(0xFF202030);
  static const panel = Color(0xFF252540);
  static const panelRaised = Color(0xFF181824);
  static const bgCanvas = canvas;
  static const bgCard = panel;
  static const border = Color(0xFF33345A);
  static const borderSubtle = Color(0x4D33345A);
  static const textPrimary = Color(0xFFF0F0F5);
  static const textSecondary = Color(0xFFA0A8BD);
  static const textMuted = Color(0xFF95919E);
  // Mobile/Lift/Recall primary is indigo; the dashboard keeps emerald (#10B981).
  static const primary = Color(0xFF7F85FF);
  static const primaryMuted = Color(0x267F85FF);
  static const secondary = Color(0xFF2D2D44);
  static const chartYellow = Color(0xFFFDE047);
  static const chartBlue = Color(0xFF5B8FF9);
  static const chartPurple = Color(0xFF8B5CF6);
  static const chartTeal = Color(0xFF2DD4BF);
  static const chartOrange = Color(0xFFFB923C);
  static const avgLine = Color(0xFFE2E8F0);
  static const successBg = Color(0x262DD4BF);
  static const warningBg = Color(0x26FDE047);
  static const errorBg = Color(0x26FB923C);
  static const infoBg = Color(0x265B8FF9);
  static const foodGradeB = Color(0xFF84CC16);
  static const foodGreen = chartTeal;
  static const foodYellow = chartYellow;
  static const foodRed = chartOrange;
  static const foodEmpty = Color(0xFF6B7280);
  static const sleepGradientStart = Color(0xFF1E2040);
  static const sleepGradientEnd = Color(0xFF1B2A30);
  static const scoreExcellent = Color(0xFF10B981);
  static const scoreGood = chartTeal;
  static const scoreFair = chartYellow;
  static const scorePoor = chartOrange;
  static const scoreBad = Color(0xFFE2674A);
  static const scoreEmpty = foodEmpty;
  // iOS platform chrome — mirrors canonical (see shared_ui_tokens.dart).
  static const tintApp = primary;
  static const tintAppMuted = primaryMuted;
  static const glassFill = Color(0x8C1C1C2E);
  static const glassHairline = Color(0x1AFFFFFF);
  static const glassSpecular = Color(0x1AFFFFFF);
  static const success = chartTeal;
  static const warning = chartYellow;
  static const danger = chartOrange;
  static const info = chartBlue;
  static const dangerBg = errorBg;
  static const pos = scoreExcellent;
  static const neg = scoreBad;
  static const flat = textMuted;
  static const posBg = Color(0x2610B981);
  static const negBg = Color(0x26E2674A);
}

/// The Recall Material theme — the shared factory with the indigo accent.
ThemeData buildRecallTheme() => buildHealthTheme(
  accent: UiColors.primary,
  accentMuted: UiColors.primaryMuted,
);

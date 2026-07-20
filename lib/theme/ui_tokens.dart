import 'package:flutter/material.dart';
import 'package:health_anki_flutter/vendored/ui_tokens_canonical.dart' hide UiColors;

/// Recall reuses the Health design system verbatim — Outfit + DM Sans, the dark
/// navy-violet surfaces, and the yellow Recall accent.
/// Only the brand name and the accent split are app-local (mirrors how
/// mobile/Lift do it).
export 'package:health_anki_flutter/vendored/ui_tokens_canonical.dart'
    show
        UiSpacing,
        UiRadii,
        UiRadius,
        UiTypography,
        UiLayout,
        scaffoldGradient,
        UiShadows,
        UiMood,
        buildPanelDecoration,
        buildHeroPanelDecoration,
        uiReadingSerif,
        buildHealthTheme;

abstract final class UiBrand {
  static const appName = 'Recall';
  static const subtitle = 'Spaced repetition';
}

/// Colour literals mirror the canonical [UiColors] exactly — parity is enforced
/// by `scripts/check_docs_drift.py` and `test/token_parity_test.dart`. Recall's
/// accent is yellow (`UiAccents.recall`, its designated registry hue); only
/// `primary` / `primaryMuted` differ from the canonical emerald.
abstract final class UiColors {
  static const canvas = Color(0xFF111319);
  static const sidebar = Color(0xFF151821);
  static const panel = Color(0xFF1A1E27);
  static const panelRaised = Color(0xFF0E1016);
  static const bgCanvas = canvas;
  static const bgCard = panel;
  static const border = Color(0xFF2A303B);
  static const borderSubtle = Color(0x4D2A303B);
  static const textPrimary = Color(0xFFF2F4F7);
  static const textSecondary = Color(0xFFB4BAC5);
  static const textMuted = Color(0xFF9198A4);
  // Recall's primary is yellow (UiAccents.recall #FDE047); mobile/Lift are
  // indigo, the dashboard keeps emerald (#10B981).
  static const primary = Color(0xFFFDE047);
  static const primaryMuted = Color(0x26FDE047);
  static const secondary = Color(0xFF20242D);
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
  static const sleepGradientStart = Color(0xFF1B2230);
  static const sleepGradientEnd = Color(0xFF17231F);
  static const scoreExcellent = Color(0xFF10B981);
  static const scoreGood = chartTeal;
  static const scoreFair = chartYellow;
  static const scorePoor = chartOrange;
  static const scoreBad = Color(0xFFE2674A);
  static const scoreEmpty = foodEmpty;
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

/// The Recall Material theme — the shared factory with the yellow accent.
ThemeData buildRecallTheme() => buildHealthTheme(
  accent: UiColors.primary,
  accentMuted: UiColors.primaryMuted,
);

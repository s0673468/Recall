import 'package:flutter/material.dart';
import 'package:health_anki_flutter/vendored/ui_tokens_canonical.dart'
    show UiMood, UiRadii, UiSpacing;

/// Geometry remains shared; Recall owns its palette, typography, and surfaces.
/// The quiet design intentionally differs from the vendored Health theme.
export 'package:health_anki_flutter/vendored/ui_tokens_canonical.dart'
    show
        UiSpacing,
        UiRadii,
        UiRadius,
        UiTypography,
        UiLayout,
        UiShadows,
        UiMood,
        uiReadingSerif,
        buildHealthTheme;

abstract final class UiBrand {
  static const appName = 'Recall';
  static const subtitle = 'Spaced repetition';
}

abstract final class UiColors {
  static const canvas = Color(0xFF181A1C);
  static const sidebar = canvas;
  static const panel = Color(0xFF202325);
  static const panelRaised = Color(0xFF282B2D);
  static const bgCanvas = canvas;
  static const bgCard = panel;
  static const border = Color(0xFF363A3D);
  static const borderSubtle = border;
  static const textPrimary = Color(0xFFEBEAE6);
  static const textSecondary = Color(0xFFBEC2C3);
  static const textMuted = Color(0xFFA0A6A9);
  static const primary = Color(0xFFD4C18D);
  static const primaryMuted = Color(0x1FD4C18D);
  static const secondary = panelRaised;
  static const chartYellow = primary;
  static const chartBlue = Color(0xFFABC1CD);
  static const chartPurple = Color(0xFFB9ACBF);
  static const chartTeal = Color(0xFFA7BFB0);
  static const chartOrange = Color(0xFFD4AA98);
  static const avgLine = textSecondary;
  static const successBg = Color(0x1FA7BFB0);
  static const warningBg = primaryMuted;
  static const errorBg = Color(0x1FD4AA98);
  static const infoBg = Color(0x1FABC1CD);
  static const foodGradeB = Color(0xFFB7BF9E);
  static const foodGreen = chartTeal;
  static const foodYellow = chartYellow;
  static const foodRed = chartOrange;
  static const foodEmpty = textMuted;
  // Legacy aliases retained for callers; Recall resting surfaces stay flat.
  static const sleepGradientStart = panel;
  static const sleepGradientEnd = panel;
  static const scoreExcellent = Color(0xFFB1C3B5);
  static const scoreGood = chartTeal;
  static const scoreFair = chartYellow;
  static const scorePoor = chartOrange;
  static const scoreBad = Color(0xFFD09B94);
  static const scoreEmpty = foodEmpty;
  static const success = chartTeal;
  static const warning = chartYellow;
  static const danger = chartOrange;
  static const info = chartBlue;
  static const dangerBg = errorBg;
  static const pos = scoreExcellent;
  static const neg = scoreBad;
  static const flat = textMuted;
  static const posBg = Color(0x1FB1C3B5);
  static const negBg = Color(0x1FD09B94);
}

/// Compatibility for older backdrop callers: both stops paint one flat canvas.
const scaffoldGradient = LinearGradient(
  colors: [UiColors.canvas, UiColors.canvas],
);

BoxDecoration buildPanelDecoration({Color? tint}) => BoxDecoration(
  borderRadius: BorderRadius.circular(UiRadii.group),
  border: Border.all(color: UiColors.border),
  color: tint ?? UiColors.panel,
  boxShadow: const [],
);

/// Emphasis comes from space and content, without an atmospheric wash.
BoxDecoration buildHeroPanelDecoration([UiMood? mood]) => BoxDecoration(
  borderRadius: BorderRadius.circular(UiRadii.hero),
  border: Border.all(color: UiColors.border),
  color: UiColors.panel,
  boxShadow: const [],
);

/// One system-backed typeface and flat charcoal surfaces on every platform.
ThemeData buildRecallTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: UiColors.canvas,
    canvasColor: UiColors.canvas,
    colorScheme: const ColorScheme.dark(
      primary: UiColors.primary,
      onPrimary: UiColors.canvas,
      primaryContainer: UiColors.primaryMuted,
      onPrimaryContainer: UiColors.primary,
      secondary: UiColors.secondary,
      tertiary: UiColors.success,
      onTertiary: UiColors.canvas,
      onSecondary: UiColors.textPrimary,
      surface: UiColors.panel,
      onSurface: UiColors.textPrimary,
      onSurfaceVariant: UiColors.textSecondary,
      surfaceContainerHighest: UiColors.panelRaised,
      outline: UiColors.border,
      outlineVariant: UiColors.border,
      error: UiColors.danger,
      onError: UiColors.canvas,
      surfaceTint: Colors.transparent,
    ),
  );
  final text = base.textTheme.apply(
    bodyColor: UiColors.textPrimary,
    displayColor: UiColors.textPrimary,
  );
  final textTheme = text.copyWith(
    headlineLarge: text.headlineLarge?.copyWith(
      fontSize: 30,
      fontWeight: FontWeight.w600,
      height: 1.2,
      letterSpacing: -0.4,
    ),
    headlineMedium: text.headlineMedium?.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      height: 1.25,
      letterSpacing: -0.25,
    ),
    titleLarge: text.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
    titleMedium: text.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.4,
      letterSpacing: 0,
    ),
    bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.55),
    bodyMedium: text.bodyMedium?.copyWith(
      fontSize: 14,
      height: 1.5,
      letterSpacing: 0,
    ),
    bodySmall: text.bodySmall?.copyWith(
      fontSize: 12,
      color: UiColors.textMuted,
      height: 1.5,
      letterSpacing: 0,
    ),
    labelLarge: text.labelLarge?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
  );
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(UiRadii.control),
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(UiRadii.control),
    borderSide: const BorderSide(color: UiColors.border),
  );
  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: UiColors.canvas,
      foregroundColor: UiColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: UiColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UiRadii.group),
        side: const BorderSide(color: UiColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.transparent,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: UiColors.primary, width: 1.5),
      ),
      hintStyle: textTheme.bodyMedium?.copyWith(color: UiColors.textMuted),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: UiSpacing.md,
        vertical: UiSpacing.sm,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UiColors.primary,
        foregroundColor: UiColors.canvas,
        minimumSize: const Size(48, 48),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UiColors.textPrimary,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: UiColors.border),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UiColors.primary,
        minimumSize: const Size(48, 48),
        textStyle: textTheme.labelLarge,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: UiColors.primaryMuted,
      side: const BorderSide(color: UiColors.border),
      labelStyle: textTheme.bodyMedium,
      shape: controlShape,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      textColor: UiColors.textPrimary,
      collapsedTextColor: UiColors.textPrimary,
      iconColor: UiColors.textMuted,
      collapsedIconColor: UiColors.textMuted,
      shape: const Border.symmetric(
        horizontal: BorderSide(color: UiColors.border),
      ),
      collapsedShape: const Border(top: BorderSide(color: UiColors.border)),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: UiSpacing.md),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: UiColors.panel,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: UiColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: UiColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    dividerColor: UiColors.border,
  );
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

// Recall deliberately owns its palette instead of mirroring vendored Health.
double contrast(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

void main() {
  test('quiet palette keeps body, secondary and status text readable', () {
    for (final background in [
      UiColors.canvas,
      UiColors.panel,
      UiColors.panelRaised,
    ]) {
      for (final foreground in [
        UiColors.textPrimary,
        UiColors.textSecondary,
        UiColors.textMuted,
        UiColors.primary,
        UiColors.success,
        UiColors.warning,
        UiColors.danger,
        UiColors.info,
      ]) {
        expect(
          contrast(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: '$foreground must remain readable on $background',
        );
      }
    }
  });

  test('theme controls and overlays inherit the approved Recall palette', () {
    final theme = buildRecallTheme();
    expect(theme.scaffoldBackgroundColor, const Color(0xFF181A1C));
    expect(theme.colorScheme.surface, const Color(0xFF202325));
    expect(theme.colorScheme.primary, const Color(0xFFD4C18D));
    expect(theme.colorScheme.onSurface, const Color(0xFFEBEAE6));
    expect(theme.colorScheme.surfaceTint, Colors.transparent);
    expect(theme.bottomSheetTheme.backgroundColor, UiColors.panel);
    expect(theme.dialogTheme.backgroundColor, UiColors.panel);
    final style = theme.filledButtonTheme.style!;
    final background = style.backgroundColor!.resolve({})!;
    final foreground = style.foregroundColor!.resolve({})!;
    expect(contrast(foreground, background), greaterThanOrEqualTo(4.5));
    expect(style.minimumSize!.resolve({})!.height, greaterThanOrEqualTo(48));
  });

  test('headings and body use the same system-backed typeface', () {
    final text = buildRecallTheme().textTheme;
    expect(text.headlineMedium!.fontFamily, text.bodyMedium!.fontFamily);
    expect(text.headlineMedium!.fontFamily, isNot(contains('Outfit')));
    expect(text.bodyMedium!.fontFamily, isNot(contains('DMSans')));
    expect(text.bodyMedium!.fontFamily, isNot(contains('DM Sans')));
    expect(text.headlineMedium!.fontWeight, FontWeight.w600);
  });

  test('all resting surface factories are flat', () {
    for (final decoration in [
      buildPanelDecoration(),
      buildHeroPanelDecoration(),
      buildHeroPanelDecoration(UiMood.nocturne),
    ]) {
      expect(decoration.gradient, isNull);
      expect(decoration.color, UiColors.panel);
      expect(decoration.boxShadow, isEmpty);
    }
    expect(scaffoldGradient.colors.toSet(), {UiColors.canvas});
  });
}

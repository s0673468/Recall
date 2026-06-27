import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';
import 'package:health_flutter_shared/ui_tokens_canonical.dart' as canon;

/// Compile-time mirror of the Python `canonical_ui_token_drifts` check: every
/// non-accent UiColors token must equal the canonical shared source. Recall's
/// accent is yellow (`UiAccents.recall`, its designated registry hue) — the one
/// allowed divergence.
void main() {
  test('UiColors palette mirrors the canonical shared source', () {
    final mirrored = <String, List<Color>>{
      'canvas': [UiColors.canvas, canon.UiColors.canvas],
      'sidebar': [UiColors.sidebar, canon.UiColors.sidebar],
      'panel': [UiColors.panel, canon.UiColors.panel],
      'panelRaised': [UiColors.panelRaised, canon.UiColors.panelRaised],
      'bgCanvas': [UiColors.bgCanvas, canon.UiColors.bgCanvas],
      'bgCard': [UiColors.bgCard, canon.UiColors.bgCard],
      'border': [UiColors.border, canon.UiColors.border],
      'borderSubtle': [UiColors.borderSubtle, canon.UiColors.borderSubtle],
      'textPrimary': [UiColors.textPrimary, canon.UiColors.textPrimary],
      'textSecondary': [UiColors.textSecondary, canon.UiColors.textSecondary],
      'textMuted': [UiColors.textMuted, canon.UiColors.textMuted],
      'secondary': [UiColors.secondary, canon.UiColors.secondary],
      'chartYellow': [UiColors.chartYellow, canon.UiColors.chartYellow],
      'chartBlue': [UiColors.chartBlue, canon.UiColors.chartBlue],
      'chartPurple': [UiColors.chartPurple, canon.UiColors.chartPurple],
      'chartTeal': [UiColors.chartTeal, canon.UiColors.chartTeal],
      'chartOrange': [UiColors.chartOrange, canon.UiColors.chartOrange],
      'avgLine': [UiColors.avgLine, canon.UiColors.avgLine],
      'successBg': [UiColors.successBg, canon.UiColors.successBg],
      'warningBg': [UiColors.warningBg, canon.UiColors.warningBg],
      'errorBg': [UiColors.errorBg, canon.UiColors.errorBg],
      'infoBg': [UiColors.infoBg, canon.UiColors.infoBg],
      'foodGradeB': [UiColors.foodGradeB, canon.UiColors.foodGradeB],
      'foodGreen': [UiColors.foodGreen, canon.UiColors.foodGreen],
      'foodYellow': [UiColors.foodYellow, canon.UiColors.foodYellow],
      'foodRed': [UiColors.foodRed, canon.UiColors.foodRed],
      'foodEmpty': [UiColors.foodEmpty, canon.UiColors.foodEmpty],
      'sleepGradientStart': [
        UiColors.sleepGradientStart,
        canon.UiColors.sleepGradientStart,
      ],
      'sleepGradientEnd': [
        UiColors.sleepGradientEnd,
        canon.UiColors.sleepGradientEnd,
      ],
      'scoreExcellent': [UiColors.scoreExcellent, canon.UiColors.scoreExcellent],
      'scoreGood': [UiColors.scoreGood, canon.UiColors.scoreGood],
      'scoreFair': [UiColors.scoreFair, canon.UiColors.scoreFair],
      'scorePoor': [UiColors.scorePoor, canon.UiColors.scorePoor],
      'scoreBad': [UiColors.scoreBad, canon.UiColors.scoreBad],
      'scoreEmpty': [UiColors.scoreEmpty, canon.UiColors.scoreEmpty],
      'glassFill': [UiColors.glassFill, canon.UiColors.glassFill],
      'glassHairline': [UiColors.glassHairline, canon.UiColors.glassHairline],
      'glassSpecular': [UiColors.glassSpecular, canon.UiColors.glassSpecular],
      'success': [UiColors.success, canon.UiColors.success],
      'warning': [UiColors.warning, canon.UiColors.warning],
      'danger': [UiColors.danger, canon.UiColors.danger],
      'info': [UiColors.info, canon.UiColors.info],
      'dangerBg': [UiColors.dangerBg, canon.UiColors.dangerBg],
      'pos': [UiColors.pos, canon.UiColors.pos],
      'neg': [UiColors.neg, canon.UiColors.neg],
      'flat': [UiColors.flat, canon.UiColors.flat],
      'posBg': [UiColors.posBg, canon.UiColors.posBg],
      'negBg': [UiColors.negBg, canon.UiColors.negBg],
    };
    mirrored.forEach((name, pair) {
      expect(pair[0], pair[1], reason: '$name must mirror canonical UiColors');
    });

    // Recall's accent is yellow (UiAccents.recall) — the one intentional divergence.
    expect(UiColors.primary, const Color(0xFFFDE047));
    expect(UiColors.primaryMuted, const Color(0x26FDE047));
    expect(UiColors.primary, isNot(canon.UiColors.primary));
  });
}

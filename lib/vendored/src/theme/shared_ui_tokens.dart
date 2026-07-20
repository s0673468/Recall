import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// THE canonical design-system source of truth for every Flutter surface
/// (dashboard, Track, Lift, Recall). Each app's `lib/theme/ui_tokens.dart`
/// mirrors the colour literals here and re-exports every non-colour primitive
/// below unchanged.
///
/// The ONLY values an app may legitimately diverge on are its brand strings and
/// its accent (`UiColors.primary` / `UiColors.primaryMuted`): emerald on the web
/// dashboard, indigo on mobile + Lift. Everything else is shared. Drift is caught
/// by `scripts/check_docs_drift.py` (cross-app + app-vs-canonical parity) and by
/// the per-app `token_parity_test.dart` widget tests.
///
/// See `design_system/colors_and_type.css` (the CSS mirror) and
/// `design_system/docs/flutter-css-mapping.md`.

/// Accent-usage rule (enforced by convention, documented in the design system):
///   * indigo `primary`  -> INTERACTION  (CTAs, nav, focus, selection)
///   * emerald `scoreExcellent` / the score ladder -> STATUS ("how good is this")
/// On the indigo apps these are deliberately two different "positive" colours:
/// one says "tap me", the other says "this is good". Never use the score ladder
/// for buttons, or the accent for a score.
abstract final class UiColors {
  // Quiet Instruments v3 surfaces — restrained blue-black, never pure black.
  static const canvas = Color(0xFF111319);
  static const sidebar = Color(0xFF151821);
  static const panel = Color(0xFF1A1E27);
  static const panelRaised = Color(0xFF0E1016);
  static const bgCanvas = canvas;
  static const bgCard = panel;
  static const border = Color(0xFF2A303B);
  static const borderSubtle = Color(0x4D2A303B);

  // Text.
  static const textPrimary = Color(0xFFF2F4F7);
  static const textSecondary = Color(0xFFB4BAC5);
  static const textMuted = Color(0xFF9198A4);

  // Default accent = emerald (the web dashboard). Mobile + Lift override this
  // pair in their own ui_tokens.dart with indigo. These are the only tokens an
  // app may diverge on (see ALLOWED_UI_TOKEN_DIFFERENCES in check_docs_drift.py).
  static const primary = Color(0xFF10B981);
  static const primaryMuted = Color(0x2610B981);
  static const secondary = Color(0xFF20242D);

  // Categorical chart hues — exactly five, never a sixth.
  static const chartYellow = Color(0xFFFDE047);
  static const chartBlue = Color(0xFF5B8FF9);
  static const chartPurple = Color(0xFF8B5CF6);
  static const chartTeal = Color(0xFF2DD4BF);
  static const chartOrange = Color(0xFFFB923C);
  static const avgLine = Color(0xFFE2E8F0);

  // Semantic background tints — chart hues at 15% alpha. Never for body text.
  static const successBg = Color(0x262DD4BF);
  static const warningBg = Color(0x26FDE047);
  static const errorBg = Color(0x26FB923C);
  static const infoBg = Color(0x265B8FF9);

  // Food stoplight — reuses the chart palette so the user's mental model holds.
  static const foodGradeB = Color(0xFF84CC16);
  static const foodGreen = chartTeal;
  static const foodYellow = chartYellow;
  static const foodRed = chartOrange;
  static const foodEmpty = Color(0xFF6B7280);

  // Gradient stops — the only two gradients the design system allows.
  static const sleepGradientStart = Color(0xFF1B2230);
  static const sleepGradientEnd = Color(0xFF17231F);

  // Score-health ladder (0-100): one colour language for "how good is this".
  // Explicit emerald (not `primary`) so "excellent" stays green even where the
  // product accent is indigo.
  static const scoreExcellent = Color(0xFF10B981);
  static const scoreGood = chartTeal;
  static const scoreFair = chartYellow;
  static const scorePoor = chartOrange;
  static const scoreBad = Color(0xFFE2674A);
  static const scoreEmpty = foodEmpty;

  // Semantic foregrounds — intent-named aliases onto the 5-hue set. "danger"
  // is the system's single error hue (orange); there is no separate red.
  static const success = chartTeal; // #2DD4BF
  static const warning = chartYellow; // #FDE047
  static const danger = chartOrange; // #FB923C
  static const info = chartBlue; // #5B8FF9
  static const dangerBg = errorBg;

  // Directional (signed deltas / trends): up-good green, down-bad deep red,
  // flat grey. Stays inside the palette (reuses the score ladder hues).
  static const pos = scoreExcellent; // #10B981
  static const neg = scoreBad; // #E2674A
  static const flat = textMuted;
  static const posBg = Color(0x2610B981);
  static const negBg = Color(0x26E2674A);
}

/// Depth tokens. Resting content is flat; only overlays may float.
abstract final class UiShadows {
  static const card = Color(0x00000000);
  static const deep = Color(0x47000000);
  static const floating = BoxShadow(
    color: deep,
    blurRadius: 32,
    offset: Offset(0, 12),
  );
}

/// Weather-mood palettes for UI atmosphere: six named moods a surface can
/// borrow as an ambient wash. Retained as inert shared infrastructure (no
/// caller feeds a live mood today); kept so [MoodScope]/[scopedPanelColor] keep
/// their types and the token-parity guards stay stable.
///
/// Rules: atmosphere ONLY — a faint gradient and sun glow on hero cards. Never
/// buttons (accent = interaction), never scores (score ladder = status), never
/// body text.
class UiMood {
  final String name;

  /// UI-adapted mood accent — bright enough to read on [UiColors.panel].
  final Color accent;

  /// The mood's deep sky — blends toward [UiColors.panel] in hero washes.
  final Color deep;

  /// The mood's sun tone — used for the hero sun-glow radial.
  final Color sun;

  const UiMood._(this.name, this.accent, this.deep, this.sun);

  static const dawn = UiMood._(
    'dawn',
    Color(0xFF5496F0),
    Color(0xFF0A1040),
    Color(0xFFFACD60),
  );
  static const ember = UiMood._(
    'ember',
    Color(0xFFFF7A60),
    Color(0xFF2E0A22),
    Color(0xFFFF8A42),
  );
  static const storm = UiMood._(
    'storm',
    Color(0xFF94A8FF),
    Color(0xFF0E0C24),
    Color(0xFFC4CEE8),
  );
  static const mist = UiMood._(
    'mist',
    Color(0xFF8CB0BA),
    Color(0xFF1A202A),
    Color(0xFFD6DADE),
  );
  static const verdant = UiMood._(
    'verdant',
    Color(0xFF60DCA0),
    Color(0xFF082A3E),
    Color(0xFFF2E87A),
  );
  static const nocturne = UiMood._(
    'nocturne',
    Color(0xFFAC80DC),
    Color(0xFF100A28),
    Color(0xFFD8A05C),
  );

  static const values = [dawn, ember, storm, mist, verdant, nocturne];

  /// Resolves a manifest palette name ("verdant", "storm+ember") to a mood;
  /// blends resolve to their primary. Unknown or empty names return null so
  /// surfaces fall back to the plain panel.
  static UiMood? byName(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final key = raw.split('+').first.trim().toLowerCase();
    for (final mood in values) {
      if (mood.name == key) return mood;
    }
    return null;
  }
}

/// Per-product accent registry — the Dart twin of the `--accent-*` block in
/// `colors_and_type.css` (LAYER 3 · PER-PRODUCT ACCENT REGISTRY). One shared dark
/// core; the accent is the single token that shifts per surface. Every entry is
/// one of the seven brand hues — no new colours, and orange (`#FB923C`) stays
/// semantic-only.
///
/// The Health apps already read their own accent as `UiColors.primary` (emerald
/// on web, indigo on mobile/Lift, yellow on Recall); this registry exists so a
/// cross-surface artifact can resolve any product's accent from one place without
/// reaching into another product's tokens. Mirrors the CSS registry exactly.
abstract final class UiAccents {
  static const healthWeb = Color(0xFF10B981); // emerald — dashboard primary
  static const healthMobile = Color(0xFF7F85FF); // indigo — mobile primary
  static const surf = Color(0xFF2DD4BF); // teal — Surf Check
  static const news = Color(0xFF5B8FF9); // blue — Newsreel
  static const odds = Color(0xFF8B5CF6); // purple — Oddsreel
  static const lift = Color(0xFF7F85FF); // indigo — matches logo-lift.svg
  static const recall = Color(0xFFFDE047); // yellow — Recall
}

/// One shared colour language for "how good is this 0-100 score", used by the
/// readiness and sleep-index cards across every app.
abstract final class UiScore {
  static Color tier(num score) {
    if (score >= 85) return UiColors.scoreExcellent;
    if (score >= 70) return UiColors.scoreGood;
    if (score >= 50) return UiColors.scoreFair;
    if (score >= 34) return UiColors.scorePoor;
    return UiColors.scoreBad;
  }

  static Color ratioTier(double ratio) => tier(ratio.clamp(0.0, 1.0) * 100);
}

/// The scaffold gradient painted behind every screen — see `--scaffold-gradient`.
const scaffoldGradient = LinearGradient(
  colors: [UiColors.sidebar, UiColors.canvas],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

/// The sleep summary card gradient — see `--sleep-card-gradient`.
const sleepCardGradient = LinearGradient(
  colors: [UiColors.sleepGradientStart, UiColors.sleepGradientEnd],
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
);

abstract final class UiSpacing {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 18;
  static const double lg = 24;
  static const double xl = 32;
  static const double cardPadding = 24;
}

abstract final class UiRadii {
  static const double hero = 20;
  static const double group = 16;
  static const double control = 12;
  static const double chip = 8;
  static const double pill = 9999;

  // Compatibility aliases for callers migrating to role-based geometry.
  static const double input = control;
  static const double card = group;
}

/// Radius tokens used by the food/move widgets.
abstract final class UiRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 9999;
  static const double card = UiRadii.group;
  // Legacy stoplight counter size until that control migrates to flat rows.
  static const double foodButton = 20;

  /// The 4px section-label accent bar's corner radius.
  static const double accentBar = 2;
}

/// Typography sizes used by widgets that style text outside the Material text
/// theme (food/move widgets, big metric numbers).
abstract final class UiTypography {
  static const double h1 = 20;
  static const double h2 = 16;
  static const double body = 14;
  static const double caption = 12;
  static const double metric = 28;
  static const double header = 24;
  static const double date = 14;
  static const double buttonCount = 36;

  /// Chart axis/legend labels and micro-caps (section labels, WHY headers).
  static const double chartLabel = 11;

  /// The single hero score number (readiness, sleep index).
  static const double scoreDisplay = 52;
}

/// Token-layer font accessors for widget code styling text OUTSIDE the
/// Material text theme (food/move tiles, big metric numbers). One place to
/// change the family; widgets never call GoogleFonts directly.
TextStyle uiBodyFont({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.dmSans(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

TextStyle uiDisplayFont({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.outfit(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Reading face for Recall card content and other long-form material. This is
/// intentionally system-backed so the design change adds no runtime font or
/// package dependency.
TextStyle uiReadingSerif({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: 'Georgia',
    fontFamilyFallback: const ['Cambria', 'Times New Roman', 'serif'],
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// The instrument voice: JetBrains Mono tracked caps for calibration-style
/// labels — section labels, chart axes, day-strip dates, sync status. Part of
/// the retro-futuristic radar language (with the hero halftone/scanline
/// atmosphere and NO SIGNAL empty states); use for LABELS AND READOUTS only,
/// never body copy.
/// The instrument mono family, for composing into existing chart label
/// styles without rebuilding them.
String? get uiMonoFamily => GoogleFonts.jetBrainsMono().fontFamily;

TextStyle uiInstrumentLabel({
  double fontSize = UiTypography.chartLabel,
  Color color = UiColors.textSecondary,
  double letterSpacing = 1.2,
  FontWeight fontWeight = FontWeight.w600,
}) {
  return GoogleFonts.jetBrainsMono(
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    color: color,
  );
}

/// Dashboard-wide layout grid. Content caps at [maxContent]; chart cards use
/// [cardWidth] so two cards + [gap] = [maxContent].
abstract final class UiLayout {
  static const double maxContent = 1000;
  static const double gap = UiSpacing.lg; // 24
  static const double cardWidth = (maxContent - gap) / 2; // 488
  static const double wideBreakpoint = maxContent + 80;
  static const double topInset = 40; // breathing room above content
}

/// A bounded content group: flat panel fill, structural hairline, no shadow.
BoxDecoration buildPanelDecoration({Color? tint}) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(UiRadii.group),
    border: Border.all(color: UiColors.border),
    color: tint ?? UiColors.panel,
    boxShadow: const [],
  );
}

/// The hero-card decoration: the standard panel washed diagonally so the one
/// card that carries the day (Readiness) reads as louder than the rest —
/// everything else stays [buildPanelDecoration], which is what makes the hero
/// tier read as hierarchy.
///
/// With no [mood] the wash is a faint neutral lift (a subtle blue-grey pulled
/// from [UiColors.border]); an optional mood washes with its deep sky instead.
BoxDecoration buildHeroPanelDecoration([UiMood? mood]) {
  final wash = mood != null
      ? Color.lerp(UiColors.panel, mood.deep, 0.55)!
      : Color.lerp(UiColors.panel, UiColors.border, 0.45)!;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(UiRadii.hero),
    border: Border.all(color: UiColors.border),
    gradient: LinearGradient(
      colors: [wash, UiColors.panel],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    boxShadow: const [],
  );
}

/// The ambient-card decoration: the standard panel with a faint wash of the
/// day's mood — every card inside a MoodScope wears this, so the whole
/// screen carries one hue family while the hero tier stays clearly louder.
BoxDecoration buildAmbientPanelDecoration(UiMood mood) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(UiRadii.group),
    border: Border.all(color: UiColors.border),
    gradient: LinearGradient(
      colors: [Color.lerp(UiColors.panel, mood.deep, 0.18)!, UiColors.panel],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    boxShadow: const [],
  );
}

/// Pick a clean y-axis interval that produces ~4-5 evenly spaced labels.
double cleanYInterval(double minY, double maxY) {
  final range = maxY - minY;
  if (range <= 0) return 1;
  const targets = [
    0.1,
    0.2,
    0.25,
    0.5,
    1.0,
    2.0,
    5.0,
    10.0,
    20.0,
    25.0,
    50.0,
    100.0,
    200.0,
    250.0,
    500.0,
    1000.0,
  ];
  for (final step in targets) {
    if (range / step <= 6) return step;
  }
  return range / 4;
}

/// The single Material theme factory for every Health app. Apps pass only what
/// genuinely differs — their accent, and (for Lift) tighter display sizes, the
/// lifting chip style, and a bottom navigation bar theme. Everything else is
/// identical, so there is one place to change the shared look.
ThemeData buildHealthTheme({
  required Color accent,
  required Color accentMuted,
  double headlineLargeSize = 34,
  double headlineLargeSpacing = -0.9,
  double headlineMediumSize = 28,
  double headlineMediumSpacing = -0.6,
  bool liftChip = false,
  bool withNavigationBar = false,
}) {
  final headingFont = GoogleFonts.outfitTextTheme();
  final bodyFont = GoogleFonts.dmSansTextTheme();

  // Ink for text/icons sitting ON the accent fill (e.g. FilledButton labels): a
  // light accent like Recall's yellow needs dark ink, while the darker
  // indigo/emerald accents keep the near-white foreground. This is a no-op for
  // the existing apps and keeps any registry hue legible as a solid fill.
  final accentInk = accent.computeLuminance() > 0.5
      ? UiColors.canvas
      : UiColors.textPrimary;

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: UiColors.canvas,
    colorScheme: ColorScheme.dark(
      primary: accent,
      secondary: UiColors.secondary,
      surface: UiColors.panel,
      error: UiColors.chartOrange,
    ),
  );

  final textTheme = base.textTheme.copyWith(
    headlineLarge: headingFont.headlineLarge?.copyWith(
      fontSize: headlineLargeSize,
      fontWeight: FontWeight.w700,
      color: UiColors.textPrimary,
      letterSpacing: headlineLargeSpacing,
    ),
    headlineMedium: headingFont.headlineMedium?.copyWith(
      fontSize: headlineMediumSize,
      fontWeight: FontWeight.w700,
      color: UiColors.textPrimary,
      letterSpacing: headlineMediumSpacing,
    ),
    titleLarge: headingFont.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      color: UiColors.textPrimary,
    ),
    titleMedium: headingFont.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: UiColors.textPrimary,
    ),
    bodyLarge: bodyFont.bodyLarge?.copyWith(
      fontSize: 14,
      color: UiColors.textPrimary,
      height: 1.45,
    ),
    bodyMedium: bodyFont.bodyMedium?.copyWith(
      fontSize: 14,
      color: UiColors.textPrimary,
      height: 1.45,
    ),
    bodySmall: bodyFont.bodySmall?.copyWith(
      fontSize: 12,
      color: UiColors.textMuted,
      height: 1.4,
    ),
    labelLarge: bodyFont.labelLarge?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: UiColors.textPrimary,
    ),
  );

  final chipTheme = liftChip
      ? ChipThemeData(
          backgroundColor: UiColors.panelRaised,
          selectedColor: accentMuted,
          side: const BorderSide(color: UiColors.border),
          labelStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UiRadii.pill),
          ),
        )
      : base.chipTheme.copyWith(
          backgroundColor: UiColors.secondary,
          selectedColor: accent.withValues(alpha: 0.18),
          side: const BorderSide(color: UiColors.border),
          labelStyle: textTheme.bodySmall?.copyWith(
            color: UiColors.textSecondary,
          ),
          secondaryLabelStyle: textTheme.bodySmall?.copyWith(
            color: UiColors.textPrimary,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UiRadii.pill),
          ),
        );

  final navigationBarTheme = withNavigationBar
      ? NavigationBarThemeData(
          backgroundColor: UiColors.sidebar,
          indicatorColor: accentMuted,
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? accent
                  : UiColors.textSecondary,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => textTheme.bodySmall?.copyWith(
              color: states.contains(WidgetState.selected)
                  ? accent
                  : UiColors.textSecondary,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        )
      : null;

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: UiColors.textPrimary,
      titleTextStyle: textTheme.titleLarge,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: UiColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UiRadii.group),
        side: const BorderSide(color: UiColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UiColors.panelRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UiRadii.control),
        borderSide: const BorderSide(color: UiColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UiRadii.control),
        borderSide: const BorderSide(color: UiColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(UiRadii.control),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: UiSpacing.md,
        vertical: UiSpacing.md,
      ),
    ),
    chipTheme: chipTheme,
    navigationBarTheme: navigationBarTheme,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: accentInk,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UiRadii.control),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UiColors.textPrimary,
        side: const BorderSide(color: UiColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UiRadii.control),
        ),
      ),
    ),
    dividerColor: UiColors.border,
  );
}

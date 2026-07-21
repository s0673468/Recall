import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/cloze.dart';
import '../../domain/inline_html.dart';

/// Renders a note field. Anki content is light HTML, optionally with cloze
/// deletions and inline LaTeX delimited by `\( … \)`. The pipeline is:
///
///   1. split Anki cloze markup (`{{cN::…}}`) out first ([parseCloze]);
///   2. for each non-cloze segment, parse the supported inline-HTML subset
///      ([parseInlineHtml]) into styled spans (bold/italic/colour/lists/…);
///   3. extract inline `\( … \)` math out of each text run and render it with
///      flutter_math_fork;
///   4. compose everything into a single `SelectableText.rich`.
///
/// Cloze deletions render as accent pills: hidden (`[…]`/`[hint]`) when
/// [revealCloze] is false (the front), revealed + highlighted when true (the
/// back). The Recall pipeline collapses a cloze note to a single card with no
/// per-index information, so *all* deletions are treated as active (Anki's
/// single-cloze fallback).
///
/// When a face carries display (block) math the client can't render inline, the
/// server-side [ReviewCard.latexSvg] is drawn via flutter_svg instead — a
/// defensive fallback (the column is empty in practice).
class CardFace extends StatelessWidget {
  final String html;
  final bool hasLatex;
  final TextStyle style;

  /// Raw `<svg …>` markup for display-math faces (usually null).
  final String? latexSvg;

  /// Reveal cloze deletions (the back face) instead of hiding them (the front).
  final bool revealCloze;

  /// Stable key (e.g. `"$cardId:front"`) for the parse-tree memo. Null disables
  /// caching (tests / one-off renders).
  final String? cacheKey;

  const CardFace({
    super.key,
    required this.html,
    required this.hasLatex,
    required this.style,
    this.latexSvg,
    this.revealCloze = false,
    this.cacheKey,
  });

  /// Math delimiters, as a single alternation with one capture group each:
  ///   group 1 — inline `\( … \)`
  ///   group 2 — display `\[ … \]`  (the backslash is REQUIRED, so literal
  ///             brackets like `E[X]`, `[CLS]`, `[32,10]` never match)
  ///   group 3 — display `$$ … $$`
  /// All branches are non-greedy so adjacent expressions don't merge.
  static final _mathRe = RegExp(
    r'\\\((.+?)\\\)|\\\[(.+?)\\\]|\$\$(.+?)\$\$',
    dotAll: true,
  );

  TextStyle get _readingStyle => style.merge(uiReadingSerif());

  @override
  Widget build(BuildContext context) {
    // Display-math fallback: a LaTeX face with NO delimiter the client can
    // render (`\( … \)`, `\[ … \]`, or `$$ … $$`), but a server-rendered SVG
    // available. Whenever any renderable delimiter is present the client path
    // wins. Empty in practice.
    final svg = latexSvg;
    final hasRenderableMath = html.contains(r'\(') ||
        html.contains(r'\[') ||
        html.contains(r'$$');
    if (hasLatex && svg != null && !hasRenderableMath) {
      return _SvgFace(svg: svg, style: _readingStyle);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        // Cloze first (only when present), then HTML, then math. A face with no
        // cloze markup takes the exact HTML+math path unchanged.
        final spans = isCloze(html)
            ? _buildClozeSpans(maxWidth)
            : _buildHtmlSpans(html, maxWidth, cacheKey: cacheKey);

        return SelectableText.rich(
          TextSpan(style: _readingStyle, children: _trimSpans(spans)),
          textAlign: TextAlign.center,
        );
      },
    );
  }

  /// Build spans for a plain (non-cloze) HTML string — the Spec-8 pipeline,
  /// reused for each cloze plain segment too.
  List<InlineSpan> _buildHtmlSpans(
    String html,
    double maxWidth, {
    String? cacheKey,
  }) {
    final spans = <InlineSpan>[];
    _appendHtmlSpans(spans, html, maxWidth, false, cacheKey: cacheKey);
    return spans;
  }

  /// Append an HTML string's spans (HTML nodes → math per text run) into
  /// [spans], threading [previousWasMath] so punctuation stays glued to math
  /// across segment boundaries. Returns the new previousWasMath.
  bool _appendHtmlSpans(
    List<InlineSpan> spans,
    String html,
    double maxWidth,
    bool previousWasMath, {
    String? cacheKey,
    bool trimEdges = true,
    TextStyle? baseStyle,
  }) {
    // Cloze sub-segments (trimEdges:false) keep boundary breaks and aren't
    // cached; the whole-face non-cloze path caches with trimmed edges.
    final nodes = trimEdges
        ? parseInlineHtmlCached(html, cacheKey: cacheKey)
        : parseInlineHtml(html, trimEdges: false);
    var prevMath = previousWasMath;
    for (final node in nodes) {
      switch (node) {
        case HtmlText(:final text, :final style):
          prevMath = _appendTextWithMath(
            spans: spans,
            text: text,
            nodeStyle: style,
            maxWidth: maxWidth,
            previousWasMath: prevMath,
            baseStyle: baseStyle,
          );
        case HtmlBreak():
          spans.add(const TextSpan(text: '\n'));
          prevMath = false;
        case final HtmlImage img:
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _ImageFragment(node: img, style: style),
            ),
          );
          prevMath = false;
      }
    }
    return prevMath;
  }

  /// Build spans for a cloze face: split cloze deletions out, feed the plain
  /// segments through the HTML+math pipeline, and render each deletion as a
  /// pill (hidden or revealed per [revealCloze]).
  ///
  /// Each plain segment is HTML-parsed independently (the spec's "split cloze
  /// first, then feed segments through the HTML path"), so an HTML tag that
  /// *straddles* a deletion (e.g. `<b>before {{c1::x}} after</b>`) does not
  /// carry its styling across the boundary. Real cards don't wrap formatting
  /// around a deletion, so this is an accepted limitation of the composition.
  List<InlineSpan> _buildClozeSpans(double maxWidth) {
    final nodes = parseClozeCached(html, cacheKey: cacheKey);
    final spans = <InlineSpan>[];
    var prevMath = false;
    for (final node in nodes) {
      switch (node) {
        case final ClozeText t:
          // Plain segments are small (cache the whole cloze parse, not each)
          // and keep boundary breaks so a <br> next to a deletion survives.
          prevMath = _appendHtmlSpans(
            spans,
            t.text,
            maxWidth,
            prevMath,
            trimEdges: false,
          );
        case final ClozeDeletion d:
          spans.add(_clozePillSpan(d, maxWidth));
          prevMath = false;
      }
    }
    return spans;
  }

  /// A single cloze deletion as an accent pill.
  InlineSpan _clozePillSpan(ClozeDeletion d, double maxWidth) {
    final pillStyle = _readingStyle.copyWith(color: UiColors.primary);

    if (revealCloze) {
      final content = <InlineSpan>[];
      _appendClozeContent(content, d.content, maxWidth, pillStyle);
      if (content.isNotEmpty) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _ClozePill(
            child: Text.rich(TextSpan(style: pillStyle, children: content)),
          ),
        );
      }
      // Empty deletion → fall through to the placeholder label.
    }

    final label = (d.hint != null) ? '[${d.hint}]' : '[…]';
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _ClozePill(child: Text(label, style: pillStyle)),
    );
  }

  /// Render a deletion's (recursively parsed) content, so a nested cloze shows
  /// as a nested pill and inner HTML/math still resolves.
  void _appendClozeContent(
    List<InlineSpan> spans,
    List<ClozeNode> content,
    double maxWidth,
    TextStyle pillStyle,
  ) {
    var prevMath = false;
    for (final node in content) {
      switch (node) {
        case final ClozeText t:
          prevMath = _appendHtmlSpans(
            spans,
            t.text,
            maxWidth,
            prevMath,
            trimEdges: false,
            baseStyle: pillStyle, // math inside the pill picks up the accent
          );
        case final ClozeDeletion nested:
          spans.add(_clozePillSpan(nested, maxWidth));
          prevMath = false;
      }
    }
  }

  /// Split one text run on inline math, appending styled `TextSpan`s and math
  /// `WidgetSpan`s. Returns whether the run ended on a math fragment (so the
  /// next run keeps leading punctuation glued to it).
  bool _appendTextWithMath({
    required List<InlineSpan> spans,
    required String text,
    required InlineStyle nodeStyle,
    required double maxWidth,
    required bool previousWasMath,
    TextStyle? baseStyle,
  }) {
    final resolved = _resolveStyle(nodeStyle);
    final mathBase = baseStyle ?? _readingStyle;
    var last = 0;
    var prevMath = previousWasMath;

    void addText(String piece) {
      final cleaned = prevMath ? _keepLeadingPunctuationWithMath(piece) : piece;
      if (cleaned.isNotEmpty) {
        spans.add(TextSpan(text: cleaned, style: resolved));
      }
      prevMath = false;
    }

    for (final m in _mathRe.allMatches(text)) {
      if (m.start > last) addText(text.substring(last, m.start));
      // group 1 = inline `\( … \)`; groups 2/3 = display (`\[ … \]` / `$$ … $$`).
      final inline = m.group(1);
      final isDisplay = inline == null;
      final expression = inline ?? m.group(2) ?? m.group(3)!;
      if (isDisplay) {
        // Block math sits alone on its line so the parent's TextAlign.center
        // centers it: a `\n` before (unless already at line start) and after.
        if (!_atLineStart(spans)) spans.add(const TextSpan(text: '\n'));
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _MathFragment(
              expression: expression,
              fallback: m.group(0)!,
              maxWidth: maxWidth,
              style: mathBase.merge(resolved),
              display: true,
            ),
          ),
        );
        spans.add(const TextSpan(text: '\n'));
        prevMath = false; // ended on a newline — no punctuation gluing
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _MathFragment(
              expression: expression,
              fallback: m.group(0)!,
              maxWidth: maxWidth,
              style: mathBase.merge(resolved),
            ),
          ),
        );
        prevMath = true;
      }
      last = m.end;
    }
    if (last < text.length) addText(text.substring(last));
    return prevMath;
  }

  /// Turn the parsed [InlineStyle] into concrete text overrides layered over the
  /// ambient face style.
  TextStyle? _resolveStyle(InlineStyle s) {
    if (s.isPlain) return null;
    return TextStyle(
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: s.underline ? TextDecoration.underline : null,
      color: s.colorArgb == null ? null : Color(s.colorArgb!),
      fontFamily: s.code ? 'monospace' : null,
      fontFeatures: [
        if (s.subscript) const FontFeature.subscripts(),
        if (s.superscript) const FontFeature.superscripts(),
      ],
    );
  }

  /// Collapse a trailing newline and a leading one so block breaks don't leave
  /// blank first/last lines.
  static List<InlineSpan> _trimSpans(List<InlineSpan> spans) {
    if (spans.isEmpty) return spans;
    var start = 0;
    var end = spans.length;
    bool isNewline(InlineSpan s) => s is TextSpan && s.text == '\n';
    while (start < end && isNewline(spans[start])) {
      start++;
    }
    while (end > start && isNewline(spans[end - 1])) {
      end--;
    }
    return spans.sublist(start, end);
  }

  /// Whether the next span would start a fresh line: nothing emitted yet, or the
  /// previous span is a text run ending in a newline. A WidgetSpan (math / image
  /// / pill) counts as mid-line.
  static bool _atLineStart(List<InlineSpan> spans) {
    if (spans.isEmpty) return true;
    final last = spans.last;
    if (last is TextSpan) {
      final t = last.text;
      return t != null && t.endsWith('\n');
    }
    return false;
  }

  static String _keepLeadingPunctuationWithMath(String s) {
    return s.replaceFirstMapped(
      RegExp(r'^\s*([.,;:!?])'),
      (m) => '⁠${m.group(1)}',
    );
  }
}

class _MathFragment extends StatelessWidget {
  final String expression;
  final String fallback;
  final double maxWidth;
  final TextStyle style;

  /// Block math (`\[ … \]` / `$$ … $$`): rendered in [MathStyle.display] and
  /// NOT line-broken. Inline math stays [MathStyle.text] with `texBreak()`.
  final bool display;

  const _MathFragment({
    required this.expression,
    required this.fallback,
    required this.maxWidth,
    required this.style,
    this.display = false,
  });

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      expression,
      textStyle: style,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      onErrorFallback: (_) => Text(fallback, style: style),
    );
    // Inline line-breaking (`texBreak`) is wrong for block math — a display
    // fragment stays a single unbroken unit, constrained but not wrapped.
    final Widget child;
    if (display) {
      child = math;
    } else {
      final broken = math.texBreak().parts;
      child = broken.length > 1
          ? Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: broken,
            )
          : math;
    }

    if (!maxWidth.isFinite) {
      return child;
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    );
  }
}

/// The accent-tinted pill wrapping a cloze deletion — a placeholder (`[…]` /
/// `[hint]`) when hidden, or the revealed answer when shown. Recall's yellow
/// accent (`UiAccents.recall`) at muted strength, per the design tokens.
class _ClozePill extends StatelessWidget {
  final Widget child;
  const _ClozePill({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: UiColors.primaryMuted,
        borderRadius: BorderRadius.circular(UiRadius.sm),
        border: Border.all(color: UiColors.primary.withValues(alpha: 0.35)),
      ),
      child: child,
    );
  }
}

/// A note image. Absolute `https` sources render via [Image.network] with a
/// broken-image fallback; anything relative (Anki `collection.media` that was
/// never uploaded) shows a small "media not synced" chip.
class _ImageFragment extends StatelessWidget {
  final HtmlImage node;
  final TextStyle style;

  const _ImageFragment({required this.node, required this.style});

  @override
  Widget build(BuildContext context) {
    if (node.synced) {
      return Image.network(
        node.url!,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => _chip(
          icon: Icons.broken_image_outlined,
          label: 'image unavailable',
        ),
      );
    }
    return _chip(
      icon: Icons.image_not_supported_outlined,
      label: 'media not synced',
    );
  }

  Widget _chip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UiSpacing.xs,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: UiColors.secondary,
        borderRadius: BorderRadius.circular(UiRadii.pill),
        border: Border.all(color: UiColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: UiColors.textMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(color: UiColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Renders the server-side display-math SVG, tinted to the face colour (Anki
/// LaTeX SVGs are monochrome black-on-transparent) and constrained to the card.
class _SvgFace extends StatelessWidget {
  final String svg;
  final TextStyle style;

  const _SvgFace({required this.svg, required this.style});

  @override
  Widget build(BuildContext context) {
    final tint = style.color ?? UiColors.textPrimary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: SvgPicture.string(
            svg,
            fit: BoxFit.contain,
            colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
            placeholderBuilder: (_) =>
                Text(_svgError, textAlign: TextAlign.center, style: style),
          ),
        );
      },
    );
  }

  static const _svgError = '⋯';
}

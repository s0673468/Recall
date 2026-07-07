import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../theme/ui_tokens.dart';
import '../../domain/inline_html.dart';

/// Renders a note field. Anki content is light HTML, optionally with inline
/// LaTeX delimited by `\( … \)`. The pipeline is:
///
///   1. parse the supported inline-HTML subset ([parseInlineHtml]) into styled
///      spans (bold/italic/underline/colour/code/sub-sup/lists/images);
///   2. extract inline `\( … \)` math out of each text run and render it with
///      flutter_math_fork;
///   3. compose everything into a single `SelectableText.rich`.
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

  /// Stable key (e.g. `"$cardId:front"`) for the parse-tree memo. Null disables
  /// caching (tests / one-off renders).
  final String? cacheKey;

  const CardFace({
    super.key,
    required this.html,
    required this.hasLatex,
    required this.style,
    this.latexSvg,
    this.cacheKey,
  });

  static final _mathRe = RegExp(r'\\\((.+?)\\\)', dotAll: true);

  @override
  Widget build(BuildContext context) {
    // Display-math fallback: a LaTeX face with no inline `\( … \)` the client
    // can render, but a server-rendered SVG available. Empty in practice.
    final svg = latexSvg;
    if (hasLatex && svg != null && !html.contains(r'\(')) {
      return _SvgFace(svg: svg, style: style);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        final nodes = parseInlineHtmlCached(html, cacheKey: cacheKey);
        final spans = <InlineSpan>[];
        var previousWasMath = false;

        for (final node in nodes) {
          switch (node) {
            case HtmlText(:final text, :final style):
              previousWasMath = _appendTextWithMath(
                spans: spans,
                text: text,
                nodeStyle: style,
                maxWidth: maxWidth,
                previousWasMath: previousWasMath,
              );
            case HtmlBreak():
              spans.add(const TextSpan(text: '\n'));
              previousWasMath = false;
            case final HtmlImage img:
              spans.add(
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _ImageFragment(node: img, style: style),
                ),
              );
              previousWasMath = false;
          }
        }

        return SelectableText.rich(
          TextSpan(style: style, children: _trimSpans(spans)),
          textAlign: TextAlign.center,
        );
      },
    );
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
  }) {
    final resolved = _resolveStyle(nodeStyle);
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
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MathFragment(
            expression: m.group(1)!,
            fallback: m.group(0)!,
            maxWidth: maxWidth,
            style: style.merge(resolved),
          ),
        ),
      );
      prevMath = true;
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

  const _MathFragment({
    required this.expression,
    required this.fallback,
    required this.maxWidth,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      expression,
      textStyle: style,
      mathStyle: MathStyle.text,
      onErrorFallback: (_) => Text(fallback, style: style),
    );
    final broken = math.texBreak().parts;
    final child = broken.length > 1
        ? Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: broken,
          )
        : math;

    if (!maxWidth.isFinite) {
      return child;
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
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
    return _chip(icon: Icons.image_not_supported_outlined, label: 'media not synced');
  }

  Widget _chip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: UiSpacing.xs, vertical: 4),
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

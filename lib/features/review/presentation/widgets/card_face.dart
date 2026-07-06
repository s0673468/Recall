import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Renders a note field. Anki content is light HTML, optionally with inline
/// LaTeX delimited by \( ... \). We split the math out first, render it with
/// flutter_math_fork, and clean the surrounding HTML to text. (Rich HTML like
/// bold is flattened for now — a deliberate Phase-2 polish item.)
class CardFace extends StatelessWidget {
  final String html;
  final bool hasLatex;
  final TextStyle style;

  const CardFace({
    super.key,
    required this.html,
    required this.hasLatex,
    required this.style,
  });

  static final _mathRe = RegExp(r'\\\((.+?)\\\)', dotAll: true);

  @override
  Widget build(BuildContext context) {
    if (!hasLatex || !html.contains(r'\(')) {
      return SelectableText(
        _clean(html).trim(),
        textAlign: TextAlign.center,
        style: style,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        final spans = <InlineSpan>[];
        var last = 0;
        var previousWasMath = false;

        void addText(String text) {
          final cleaned = previousWasMath
              ? _keepLeadingPunctuationWithMath(_clean(text))
              : _clean(text);
          if (cleaned.isNotEmpty) {
            spans.add(TextSpan(text: cleaned));
          }
          previousWasMath = false;
        }

        for (final m in _mathRe.allMatches(html)) {
          if (m.start > last) {
            addText(html.substring(last, m.start));
          }
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _MathFragment(
                expression: m.group(1)!,
                fallback: m.group(0)!,
                maxWidth: maxWidth,
                style: style,
              ),
            ),
          );
          previousWasMath = true;
          last = m.end;
        }
        if (last < html.length) {
          addText(html.substring(last));
        }

        return SelectableText.rich(
          TextSpan(style: style, children: spans),
          textAlign: TextAlign.center,
        );
      },
    );
  }

  /// Strip HTML to text without trimming (spaces around inline math matter).
  static String _clean(String s) {
    return s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(div|p)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  static String _keepLeadingPunctuationWithMath(String s) {
    return s.replaceFirstMapped(
      RegExp(r'^\s*([.,;:!?])'),
      (m) => '\u2060${m.group(1)}',
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

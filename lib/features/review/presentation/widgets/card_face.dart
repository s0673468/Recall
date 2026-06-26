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

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _mathRe.allMatches(html)) {
      if (m.start > last) {
        spans.add(TextSpan(text: _clean(html.substring(last, m.start))));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(
            m.group(1)!,
            textStyle: style,
            mathStyle: MathStyle.text,
            onErrorFallback: (_) => Text(m.group(0)!, style: style),
          ),
        ),
      );
      last = m.end;
    }
    if (last < html.length) {
      spans.add(TextSpan(text: _clean(html.substring(last))));
    }

    return SelectableText.rich(
      TextSpan(style: style, children: spans),
      textAlign: TextAlign.center,
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
}

import 'inline_html.dart';

final _math = RegExp(
  r'\\\((.+?)\\\)|\\\[(.+?)\\\]|\$\$(.+?)\$\$',
  dotAll: true,
);
final _tokens = RegExp(
  r'\\\(.+?\\\)|\\\[.+?\\\]|\$\$.+?\$\$|\{\{c\d+::.*?\}\}|<\s*(/?)\s*([a-zA-Z0-9]+)(?:\s+[^>]*)?\s*/?>',
  dotAll: true,
  caseSensitive: false,
);
final _list = RegExp(r'<\s*(?:ul|ol|li)\b', caseSensitive: false);

/// Only the new short answer + anchor shape opts in. Keep legacy HTML whole,
/// including lists and breaks inside formatting, clozes or maths expressions.
({String answer, String anchor})? splitCardBack(String html) {
  if (_list.hasMatch(html)) return null;
  final open = <String>[];
  for (final token in _tokens.allMatches(html)) {
    final tag = token.group(2)?.toLowerCase();
    if (tag == null) continue;
    final closing = token.group(1) == '/';
    if (tag == 'br' && open.isEmpty) {
      final answer = html.substring(0, token.start).trim();
      final anchor = html.substring(token.end).trim();
      if (answer.isEmpty || anchor.isEmpty) return null;
      final decoded = decodeEntities(answer);
      final math = _math.firstMatch(decoded);
      final onlyMath =
          math != null && math.start == 0 && math.end == decoded.length;
      final nodes = parseInlineHtml(answer.replaceAll(_math, 'math'));
      final onlyBold =
          nodes.isNotEmpty &&
          nodes.every((node) => node is HtmlText && node.style.bold);
      return onlyBold || onlyMath ? (answer: answer, anchor: anchor) : null;
    }
    if (const {
      'b',
      'strong',
      'i',
      'em',
      'u',
      'code',
      'span',
      'div',
      'p',
    }.contains(tag)) {
      if (!closing) {
        open.add(tag);
      } else if (open.isNotEmpty && open.last == tag) {
        open.removeLast();
      }
    }
  }
  return null;
}

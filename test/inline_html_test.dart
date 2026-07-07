import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/domain/inline_html.dart';

/// Flatten the parsed nodes into a debuggable "plain text" string so tests can
/// assert content without depending on span structure.
String _plain(List<InlineHtmlNode> nodes) {
  final buf = StringBuffer();
  for (final n in nodes) {
    switch (n) {
      case HtmlText(:final text):
        buf.write(text);
      case HtmlBreak():
        buf.write('\n');
      case HtmlImage():
        buf.write('[img]');
    }
  }
  return buf.toString();
}

InlineStyle _styleOf(List<InlineHtmlNode> nodes, String contains) {
  final node = nodes.whereType<HtmlText>().firstWhere(
    (t) => t.text.contains(contains),
  );
  return node.style;
}

void main() {
  group('parseInlineHtml — tags', () {
    test('bold via <b> and <strong>', () {
      for (final tag in ['b', 'strong']) {
        final nodes = parseInlineHtml('a <$tag>heavy</$tag> b');
        expect(_styleOf(nodes, 'heavy').bold, isTrue);
        expect(_styleOf(nodes, 'a ').bold, isFalse);
      }
    });

    test('italic via <i> and <em>', () {
      for (final tag in ['i', 'em']) {
        final nodes = parseInlineHtml('<$tag>slanted</$tag>');
        expect(_styleOf(nodes, 'slanted').italic, isTrue);
      }
    });

    test('underline, code, sub, sup', () {
      expect(_styleOf(parseInlineHtml('<u>x</u>'), 'x').underline, isTrue);
      expect(_styleOf(parseInlineHtml('<code>x</code>'), 'x').code, isTrue);
      expect(_styleOf(parseInlineHtml('<pre>x</pre>'), 'x').code, isTrue);
      expect(_styleOf(parseInlineHtml('H<sub>2</sub>O'), '2').subscript, isTrue);
      expect(_styleOf(parseInlineHtml('x<sup>2</sup>'), '2').superscript, isTrue);
    });

    test('<br> and block breaks split lines', () {
      expect(_plain(parseInlineHtml('a<br>b')), 'a\nb');
      expect(_plain(parseInlineHtml('<div>a</div><div>b</div>')), 'a\nb');
      expect(_plain(parseInlineHtml('<p>a</p><p>b</p>')), 'a\nb');
    });

    test('nested <b><i> compose both styles', () {
      final nodes = parseInlineHtml('<b>bold <i>and italic</i></b>');
      final inner = _styleOf(nodes, 'and italic');
      expect(inner.bold, isTrue);
      expect(inner.italic, isTrue);
      final outer = _styleOf(nodes, 'bold ');
      expect(outer.bold, isTrue);
      expect(outer.italic, isFalse);
    });

    test('unordered list renders bullet-prefixed lines', () {
      final text = _plain(
        parseInlineHtml('<ul><li>one</li><li>two</li></ul>'),
      );
      expect(text, contains('• one'));
      expect(text, contains('• two'));
    });

    test('ordered list renders numbered lines', () {
      final text = _plain(
        parseInlineHtml('<ol><li>first</li><li>second</li></ol>'),
      );
      expect(text, contains('1. first'));
      expect(text, contains('2. second'));
    });

    test('unknown tag is stripped but its content kept', () {
      final nodes = parseInlineHtml('a <mark>keep me</mark> b');
      expect(_plain(nodes), 'a keep me b');
      expect(_styleOf(nodes, 'keep me').isPlain, isTrue);
    });

    test('malformed unclosed tag never throws; content survives', () {
      final nodes = parseInlineHtml('<b>unclosed bold');
      expect(_plain(nodes), 'unclosed bold');
      expect(_styleOf(nodes, 'unclosed').bold, isTrue);
    });

    test('stray closing tag is ignored', () {
      expect(_plain(parseInlineHtml('plain</b> text')), 'plain text');
    });
  });

  group('parseInlineHtml — colour', () {
    test('span style colour is parsed and dark-clamped', () {
      final nodes = parseInlineHtml(
        '<span style="color:#000000">dark</span>',
      );
      final argb = _styleOf(nodes, 'dark').colorArgb;
      expect(argb, isNotNull);
      // Pure black would be invisible on dark; it must be lightened.
      final r = (argb! >> 16) & 0xFF;
      expect(r, greaterThan(0x80));
    });

    test('<font color> attribute maps to the palette', () {
      final nodes = parseInlineHtml('<font color="red">warn</font>');
      expect(_styleOf(nodes, 'warn').colorArgb, isNotNull);
    });
  });

  group('parseInlineHtml — images', () {
    test('absolute https image becomes a synced image node', () {
      final nodes = parseInlineHtml('<img src="https://x.test/a.png">');
      final img = nodes.whereType<HtmlImage>().single;
      expect(img.synced, isTrue);
      expect(img.url, 'https://x.test/a.png');
    });

    test('relative / collection.media image is unsynced', () {
      final nodes = parseInlineHtml('<img src="paste-123.jpg">');
      final img = nodes.whereType<HtmlImage>().single;
      expect(img.synced, isFalse);
      expect(img.rawSrc, 'paste-123.jpg');
    });
  });

  group('decodeEntities', () {
    test('named + extended entities', () {
      expect(
        decodeEntities('a&nbsp;b &amp; c &mdash; d &hellip; &times; &rsquo;'),
        'a b & c — d … × ’',
      );
    });

    test('numeric decimal and hex entities', () {
      expect(decodeEntities('&#65;&#x42;'), 'AB');
    });

    test('unknown entity is left verbatim', () {
      expect(decodeEntities('&bogus; x'), '&bogus; x');
    });
  });

  group('clampColorForDark', () {
    test('pure black is lightened above the readability floor', () {
      final out = clampColorForDark(0xFF000000);
      final r = (out >> 16) & 0xFF;
      final g = (out >> 8) & 0xFF;
      final b = out & 0xFF;
      // Neutral grey around the min-lightness floor (~0.62 * 255 ≈ 158).
      expect(r, inInclusiveRange(0x90, 0xC0));
      expect(g, inInclusiveRange(0x90, 0xC0));
      expect(b, inInclusiveRange(0x90, 0xC0));
    });

    test('an already-bright colour passes through unchanged', () {
      const brightYellow = 0xFFFFEE58;
      expect(clampColorForDark(brightYellow), brightYellow);
    });

    test('a dark saturated hue keeps its hue but gets lighter', () {
      const darkRed = 0xFF400000;
      final out = clampColorForDark(darkRed);
      final r = (out >> 16) & 0xFF;
      final g = (out >> 8) & 0xFF;
      final b = out & 0xFF;
      expect(r, greaterThan(g)); // still red-dominant
      expect(r, greaterThan(b));
      expect(r, greaterThan(0x80)); // and lightened
    });
  });

  group('parseCssColor', () {
    test('hex short + long, rgb(), and names', () {
      expect(parseCssColor('#fff'), 0xFFFFFFFF);
      expect(parseCssColor('#ff0000'), 0xFFFF0000);
      expect(parseCssColor('rgb(0, 128, 255)'), 0xFF0080FF);
      expect(parseCssColor('black'), 0xFF000000);
      expect(parseCssColor('not-a-color'), isNull);
    });
  });

  group('cloze + math coexistence', () {
    test('inline math delimiters survive HTML parsing inside a text run', () {
      // CardFace extracts \( … \) downstream; the parser must not mangle it.
      final nodes = parseInlineHtml(r'<b>vocab</b> \(=5000\)');
      expect(_plain(nodes), contains(r'\(=5000\)'));
    });
  });

  group('parseInlineHtmlCached', () {
    test('returns an identical instance on a cache hit', () {
      debugClearInlineHtmlCache();
      final a = parseInlineHtmlCached('<b>x</b>', cacheKey: '1:front');
      final b = parseInlineHtmlCached('<b>x</b>', cacheKey: '1:front');
      expect(identical(a, b), isTrue);
    });

    test('null cacheKey never caches (fresh instance each call)', () {
      final a = parseInlineHtmlCached('<b>x</b>');
      final b = parseInlineHtmlCached('<b>x</b>');
      expect(identical(a, b), isFalse);
    });
  });
}

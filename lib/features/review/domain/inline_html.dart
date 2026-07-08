/// A tiny, hand-rolled inline-HTML parser for Anki note fields.
///
/// Anki content is light HTML — mostly `<b>`, `<i>`, the occasional list,
/// coloured `<span>`/`<font>`, `<sub>`/`<sup>`, `<code>` and `<img>`. Rather
/// than pull in a heavy `flutter_html`/`flutter_widget_from_html` dependency
/// (web + Android must both stay lean), we parse the supported subset into a
/// flat list of [InlineHtmlNode]s that [CardFace] turns into `TextSpan`s.
///
/// This file is pure Dart (no Flutter imports) so it is fully unit-testable and
/// colours are carried as ARGB `int`s. Anything unrecognised has its tag
/// stripped and its text content kept — exactly the old flatten-to-text
/// behaviour, so a malformed or exotic field can never throw or vanish.
library;

/// The immutable inline style threaded down the tag stack.
class InlineStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool code;
  final bool subscript;
  final bool superscript;

  /// A clamped-for-dark ARGB colour, or null to inherit the ambient text style.
  final int? colorArgb;

  const InlineStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.code = false,
    this.subscript = false,
    this.superscript = false,
    this.colorArgb,
  });

  bool get isPlain =>
      !bold &&
      !italic &&
      !underline &&
      !code &&
      !subscript &&
      !superscript &&
      colorArgb == null;

  InlineStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? code,
    bool? subscript,
    bool? superscript,
    int? colorArgb,
    bool clearColor = false,
  }) {
    return InlineStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      code: code ?? this.code,
      subscript: subscript ?? this.subscript,
      superscript: superscript ?? this.superscript,
      colorArgb: clearColor ? null : (colorArgb ?? this.colorArgb),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InlineStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.code == code &&
      other.subscript == subscript &&
      other.superscript == superscript &&
      other.colorArgb == colorArgb;

  @override
  int get hashCode => Object.hash(
    bold,
    italic,
    underline,
    code,
    subscript,
    superscript,
    colorArgb,
  );
}

/// A node in the flattened inline stream.
sealed class InlineHtmlNode {
  const InlineHtmlNode();
}

/// A run of text carrying its resolved [InlineStyle]. `text` is already
/// entity-decoded; it may still contain inline `\( … \)` math, which
/// [CardFace] extracts downstream.
class HtmlText extends InlineHtmlNode {
  final String text;
  final InlineStyle style;
  const HtmlText(this.text, this.style);

  @override
  bool operator ==(Object other) =>
      other is HtmlText && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);
}

/// A hard line break (`<br>`, or the end of a `<div>`/`<p>`/`<li>` block).
class HtmlBreak extends InlineHtmlNode {
  const HtmlBreak();

  @override
  bool operator ==(Object other) => other is HtmlBreak;

  @override
  int get hashCode => 0x0a;
}

/// An image. [url] is a renderable absolute `https` URL; when null the source
/// is a relative / `collection.media` reference that was never uploaded, and
/// [CardFace] shows a small "media not synced" chip instead.
class HtmlImage extends InlineHtmlNode {
  final String? url;
  final String rawSrc;
  const HtmlImage({required this.url, required this.rawSrc});

  bool get synced => url != null;

  @override
  bool operator ==(Object other) =>
      other is HtmlImage && other.url == url && other.rawSrc == rawSrc;

  @override
  int get hashCode => Object.hash(url, rawSrc);
}

// ── Entity decoding ───────────────────────────────────────────────────────

const Map<String, String> _entities = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&#39;': "'",
  '&mdash;': '—',
  '&ndash;': '–',
  '&hellip;': '…',
  '&rsquo;': '’',
  '&lsquo;': '‘',
  '&rdquo;': '”',
  '&ldquo;': '“',
  '&times;': '×',
  '&divide;': '÷',
};

final RegExp _entityRe = RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);');

/// Decode the named + numeric HTML entities we care about. Unknown entities are
/// left verbatim (never throws).
String decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entityRe, (m) {
    final whole = m.group(0)!;
    final named = _entities[whole.toLowerCase()];
    if (named != null) return named;
    final body = m.group(1)!;
    if (body.startsWith('#')) {
      final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final digits = isHex ? body.substring(2) : body.substring(1);
      final code = int.tryParse(digits, radix: isHex ? 16 : 10);
      if (code != null && code > 0 && code <= 0x10ffff) {
        try {
          return String.fromCharCode(code);
        } catch (_) {
          return whole;
        }
      }
    }
    return whole;
  });
}

// ── Colour parsing + dark clamping ────────────────────────────────────────

const Map<String, int> _namedColors = {
  'black': 0xFF000000,
  'white': 0xFFFFFFFF,
  'red': 0xFFFF0000,
  'green': 0xFF008000,
  'blue': 0xFF0000FF,
  'yellow': 0xFFFFFF00,
  'orange': 0xFFFFA500,
  'purple': 0xFF800080,
  'gray': 0xFF808080,
  'grey': 0xFF808080,
  'cyan': 0xFF00FFFF,
  'magenta': 0xFFFF00FF,
  'pink': 0xFFFFC0CB,
  'brown': 0xFFA52A2A,
};

/// Parse a CSS colour (`#rgb`, `#rrggbb`, `rgb(…)`, or a common name) into an
/// opaque ARGB int, or null when it is not one we recognise.
int? parseCssColor(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  final named = _namedColors[s];
  if (named != null) return named;

  if (s.startsWith('#')) {
    s = s.substring(1);
    if (s.length == 3) {
      final r = s[0], g = s[1], b = s[2];
      s = '$r$r$g$g$b$b';
    }
    if (s.length == 6) {
      final v = int.tryParse(s, radix: 16);
      if (v != null) return 0xFF000000 | v;
    }
    return null;
  }

  final rgb = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(s);
  if (rgb != null) {
    final parts = rgb.group(1)!.split(',');
    if (parts.length >= 3) {
      int? chan(String p) {
        final t = p.trim();
        if (t.endsWith('%')) {
          final pct = double.tryParse(t.substring(0, t.length - 1));
          if (pct == null) return null;
          return (pct.clamp(0, 100) / 100 * 255).round();
        }
        final n = double.tryParse(t);
        if (n == null) return null;
        return n.clamp(0, 255).round();
      }

      final r = chan(parts[0]), g = chan(parts[1]), b = chan(parts[2]);
      if (r != null && g != null && b != null) {
        return 0xFF000000 | (r << 16) | (g << 8) | b;
      }
    }
  }
  return null;
}

/// Minimum HSL lightness a colour may have on the dark navy-violet panel, so
/// author intent (hue/saturation) survives while staying readable.
const double _minDarkLightness = 0.62;

/// Clamp an ARGB colour so it reads on a dark surface: floor its HSL lightness
/// at [_minDarkLightness], preserving hue and saturation. Bright colours pass
/// through unchanged.
int clampColorForDark(int argb) {
  final a = (argb >> 24) & 0xFF;
  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;

  final maxC = [r, g, b].reduce((x, y) => x > y ? x : y);
  final minC = [r, g, b].reduce((x, y) => x < y ? x : y);
  final l = (maxC + minC) / 2;
  if (l >= _minDarkLightness) return argb;

  final delta = maxC - minC;
  double h = 0;
  double sat = 0;
  if (delta != 0) {
    sat = delta / (1 - (2 * l - 1).abs());
    if (maxC == r) {
      h = ((g - b) / delta) % 6;
    } else if (maxC == g) {
      h = (b - r) / delta + 2;
    } else {
      h = (r - g) / delta + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
  }

  final nl = _minDarkLightness;
  final c = (1 - (2 * nl - 1).abs()) * sat;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final mm = nl - c / 2;
  double rr = 0, gg = 0, bb = 0;
  if (h < 60) {
    rr = c;
    gg = x;
  } else if (h < 120) {
    rr = x;
    gg = c;
  } else if (h < 180) {
    gg = c;
    bb = x;
  } else if (h < 240) {
    gg = x;
    bb = c;
  } else if (h < 300) {
    rr = c;
    bb = x;
  } else {
    rr = c;
    bb = x;
  }
  int ch(double v) => ((v + mm) * 255).round().clamp(0, 255);
  return (a << 24) | (ch(rr) << 16) | (ch(gg) << 8) | ch(bb);
}

// ── Parser ─────────────────────────────────────────────────────────────────

final RegExp _tagRe = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:[^>"]|"[^"]*")*)>');
final RegExp _srcRe = RegExp(
  '''src\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))''',
  caseSensitive: false,
);
final RegExp _colorAttrRe = RegExp(
  '''color\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))''',
  caseSensitive: false,
);
final RegExp _styleColorRe = RegExp(
  r'(?:^|;)\s*color\s*:\s*([^;]+)',
  caseSensitive: false,
);

/// One entry on the open-tag stack. [restore] is applied to the current node
/// list on the matching close tag (e.g. to emit a block break).
class _Frame {
  final String tag;
  final InlineStyle style;
  final int? listCounter; // set for <ol>/<ul>; null otherwise
  final bool ordered;
  int listIndex;
  _Frame(this.tag, this.style, {this.listCounter, this.ordered = false})
    : listIndex = 0;
}

/// Parse [html] into a flat list of inline nodes. Never throws.
///
/// [trimEdges] (default true) drops a leading/trailing block break so a face
/// never opens or closes on a blank line. Cloze composition parses each
/// sub-segment separately and passes false, so a `<br>` sitting at a cloze
/// boundary (e.g. `…{{c1::a}}<br>2. {{c2::b}}`) still emits its line break; the
/// caller trims the *assembled* face's edges instead.
List<InlineHtmlNode> parseInlineHtml(String html, {bool trimEdges = true}) {
  final out = <InlineHtmlNode>[];
  final stack = <_Frame>[_Frame('', const InlineStyle())];
  InlineStyle style() => stack.last.style;

  void addBreak() {
    if (out.isEmpty) {
      if (trimEdges) return; // trimmed mode: no leading break
      out.add(const HtmlBreak()); // preserve a boundary break for cloze
      return;
    }
    if (out.last is HtmlBreak) return;
    out.add(const HtmlBreak());
  }

  void addText(String raw) {
    if (raw.isEmpty) return;
    out.add(HtmlText(decodeEntities(raw), style()));
  }

  var pos = 0;
  for (final m in _tagRe.allMatches(html)) {
    if (m.start > pos) addText(html.substring(pos, m.start));
    pos = m.end;

    final closing = m.group(1) == '/';
    final tag = m.group(2)!.toLowerCase();
    final attrs = m.group(3) ?? '';

    switch (tag) {
      case 'br':
        if (!closing) addBreak();
      case 'b':
      case 'strong':
        _push(stack, tag, closing, (s) => s.copyWith(bold: true));
      case 'i':
      case 'em':
        _push(stack, tag, closing, (s) => s.copyWith(italic: true));
      case 'u':
        _push(stack, tag, closing, (s) => s.copyWith(underline: true));
      case 'code':
      case 'pre':
        _push(stack, tag, closing, (s) => s.copyWith(code: true));
      case 'sub':
        _push(stack, tag, closing, (s) => s.copyWith(subscript: true));
      case 'sup':
        _push(stack, tag, closing, (s) => s.copyWith(superscript: true));
      case 'span':
      case 'font':
        final color = _extractColor(attrs);
        _push(
          stack,
          tag,
          closing,
          color == null
              ? (s) => s
              : (s) => s.copyWith(colorArgb: clampColorForDark(color)),
        );
      case 'div':
      case 'p':
        if (closing) {
          _pop(stack, tag);
          addBreak();
        } else {
          addBreak();
          stack.add(_Frame(tag, style()));
        }
      case 'ul':
      case 'ol':
        if (closing) {
          _pop(stack, tag);
          addBreak();
        } else {
          addBreak();
          stack.add(_Frame(tag, style(), ordered: tag == 'ol', listCounter: 0));
        }
      case 'li':
        if (!closing) {
          addBreak();
          final list = _nearestList(stack);
          if (list != null && list.ordered) {
            list.listIndex += 1;
            out.add(HtmlText('${list.listIndex}. ', style()));
          } else {
            out.add(HtmlText('• ', style()));
          }
        }
      case 'img':
        if (!closing) {
          final rawSrc = _extractSrc(attrs);
          out.add(
            HtmlImage(
              url: (rawSrc.startsWith('https://')) ? rawSrc : null,
              rawSrc: rawSrc,
            ),
          );
        }
      default:
        // Unknown/unsupported tag: strip the tag, keep the content. Self-open
        // and close are both no-ops on the style stack.
        break;
    }
  }
  if (pos < html.length) addText(html.substring(pos));

  // Trim leading/trailing structural breaks (unless the caller assembles edges
  // itself, e.g. cloze sub-segments).
  if (trimEdges) {
    while (out.isNotEmpty && out.first is HtmlBreak) {
      out.removeAt(0);
    }
    while (out.isNotEmpty && out.last is HtmlBreak) {
      out.removeLast();
    }
  }
  return out;
}

void _push(
  List<_Frame> stack,
  String tag,
  bool closing,
  InlineStyle Function(InlineStyle) apply,
) {
  if (closing) {
    _pop(stack, tag);
  } else {
    stack.add(_Frame(tag, apply(stack.last.style)));
  }
}

/// Pop back to (and including) the nearest frame with a matching tag. If none
/// matches (stray close tag) the stack is left untouched.
void _pop(List<_Frame> stack, String tag) {
  for (var i = stack.length - 1; i > 0; i--) {
    if (stack[i].tag == tag) {
      stack.removeRange(i, stack.length);
      return;
    }
  }
}

_Frame? _nearestList(List<_Frame> stack) {
  for (var i = stack.length - 1; i > 0; i--) {
    if (stack[i].listCounter != null) return stack[i];
  }
  return null;
}

int? _extractColor(String attrs) {
  final style = RegExp(
    '''style\\s*=\\s*"([^"]*)"''',
    caseSensitive: false,
  ).firstMatch(attrs);
  if (style != null) {
    final c = _styleColorRe.firstMatch(style.group(1)!);
    if (c != null) {
      final parsed = parseCssColor(c.group(1)!);
      if (parsed != null) return parsed;
    }
  }
  final attr = _colorAttrRe.firstMatch(attrs);
  if (attr != null) {
    final v = attr.group(1) ?? attr.group(2) ?? attr.group(3);
    if (v != null) return parseCssColor(v);
  }
  return null;
}

String _extractSrc(String attrs) {
  final m = _srcRe.firstMatch(attrs);
  if (m == null) return '';
  return (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
}

// ── Small LRU memo ───────────────────────────────────────────────────────

const int _cacheCap = 50;
final Map<String, List<InlineHtmlNode>> _cache = {};

/// Parse with a tiny LRU keyed by (cardId, face). [CardFace] rebuilds on every
/// reveal, so memoising the pure span tree keeps parsing off the hot path.
/// A null [cacheKey] parses uncached.
List<InlineHtmlNode> parseInlineHtmlCached(String html, {String? cacheKey}) {
  if (cacheKey == null) return parseInlineHtml(html);
  final hit = _cache.remove(cacheKey);
  if (hit != null) {
    _cache[cacheKey] = hit; // move to MRU
    return hit;
  }
  final parsed = parseInlineHtml(html);
  _cache[cacheKey] = parsed;
  if (_cache.length > _cacheCap) {
    _cache.remove(_cache.keys.first);
  }
  return parsed;
}

/// Visible for tests: reset the memo so cache-hit assertions are deterministic.
void debugClearInlineHtmlCache() => _cache.clear();

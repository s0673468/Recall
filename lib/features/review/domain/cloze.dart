/// A tiny, dependency-free parser for Anki cloze markup — `{{cN::text}}` and
/// `{{cN::text::hint}}`.
///
/// The tokenizer is brace-balanced, so a cloze whose text contains nested
/// clozes (`{{c1::a {{c2::b}} }}`) is matched to the *correct* closing `}}` and
/// its inner content is parsed recursively (depth-guarded). Anything malformed
/// — an unclosed `{{c1::`, a stray brace — is emitted verbatim as text, so a
/// broken field can never throw and always renders literally.
///
/// Pure Dart (no Flutter imports) → fully unit-testable. [CardFace] turns the
/// node tree into spans, composing cloze → HTML → math.
library;

/// A node in the cloze tree.
sealed class ClozeNode {
  const ClozeNode();
}

/// A run of non-cloze text — still raw (may carry HTML / inline math), which
/// [CardFace] feeds through the HTML+math pipeline.
class ClozeText extends ClozeNode {
  final String text;
  const ClozeText(this.text);

  @override
  bool operator ==(Object other) => other is ClozeText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'ClozeText(${_short(text)})';
}

/// A cloze deletion `{{cN::content::hint}}`. [content] is recursively parsed so
/// a nested cloze is itself a [ClozeDeletion]; [hint] is the optional `::hint`
/// (null when absent or empty).
class ClozeDeletion extends ClozeNode {
  final int index;
  final List<ClozeNode> content;
  final String? hint;

  const ClozeDeletion({
    required this.index,
    required this.content,
    this.hint,
  });

  @override
  bool operator ==(Object other) =>
      other is ClozeDeletion &&
      other.index == index &&
      other.hint == hint &&
      _listEquals(other.content, content);

  @override
  int get hashCode => Object.hash(index, hint, Object.hashAll(content));

  @override
  String toString() => 'ClozeDeletion(c$index, $content, hint: $hint)';
}

/// Matches a cloze opener `{{cN::` (or a shared/multi-card ordinal list like
/// `{{c1,2::…}}`, which Anki supports) anchored at a position. Each ordinal is
/// capped at 9 digits: real indices are tiny (c1…c99), and bounding it keeps a
/// pathological long-digit run from (a) matching at all and (b) overflowing
/// int64 on native while silently parsing on web — so behavior is identical on
/// both platforms (a 10+ digit "index" is simply not a cloze → literal).
final RegExp _opener = RegExp(r'\{\{c(\d{1,9}(?:,\d{1,9})*)::');

/// Cheap detection: does this face contain any cloze opener at all?
final RegExp _detect = RegExp(r'\{\{c\d{1,9}(?:,\d{1,9})*::');

/// Whether [s] should be cloze-rendered (matches the cloze opener). A string
/// with no opener takes the plain HTML path unchanged.
bool isCloze(String s) => _detect.hasMatch(s);

/// Recursion cap for nested clozes; beyond it, inner content stays literal.
const int _maxDepth = 6;

/// Parse [s] into a flat list of cloze nodes. Never throws.
List<ClozeNode> parseCloze(String s, {int maxDepth = _maxDepth}) {
  final out = <ClozeNode>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      out.add(ClozeText(buf.toString()));
      buf.clear();
    }
  }

  var i = 0;
  while (i < s.length) {
    if (s.codeUnitAt(i) == 0x7b /* { */ && s.startsWith('{{c', i)) {
      final m = _opener.matchAsPrefix(s, i);
      if (m != null && maxDepth > 0) {
        // For a shared ordinal list (c1,2) take the first; index is only a
        // future hook (all deletions are active in the single-cloze fallback).
        // tryParse defensively (the ≤9-digit bound already precludes overflow).
        final index = int.tryParse(m.group(1)!.split(',').first);
        if (index != null) {
          final close = _findClose(s, m.end);
          if (close != null) {
            final inner = s.substring(m.end, close);
            final (text, hint) = _splitHint(inner);
            flush();
            out.add(
              ClozeDeletion(
                index: index,
                content: parseCloze(text, maxDepth: maxDepth - 1),
                hint: (hint == null || hint.isEmpty) ? null : hint,
              ),
            );
            i = close + 2; // skip the closing "}}"
            continue;
          }
        }
      }
      // Not a valid/closable cloze (or depth exhausted): emit "{" literally and
      // advance one char, so the rest is re-scanned and text is never lost.
    }
    buf.write(s[i]);
    i++;
  }
  flush();
  return out;
}

/// Find the literal `}}` that closes a cloze opened just before [from].
///
/// Tracks *content* brace depth (the opener's `{{` is not counted): `{` opens,
/// a `}` at depth > 0 closes a content group. The terminator is the first
/// literal `}}` seen at depth 0 — so balanced content groups (`\frac{a}{b}`,
/// nested `{{ … }}` clozes) are consumed inside the deletion, while a *lone*
/// unbalanced `}` stays literal content instead of stealing the close (which
/// used to drop a character). Returns the index of the closing `}}` (its first
/// `}`), or null if unclosed.
int? _findClose(String s, int from) {
  var depth = 0;
  var i = from;
  while (i < s.length) {
    final ch = s.codeUnitAt(i);
    if (ch == 0x7b) {
      depth++;
      i++;
    } else if (ch == 0x7d) {
      if (depth > 0) {
        depth--; // closes a content "{ … }" group
        i++;
      } else if (i + 1 < s.length && s.codeUnitAt(i + 1) == 0x7d) {
        return i; // the literal "}}" terminator
      } else {
        i++; // a lone "}" in content — keep it literal
      }
    } else {
      i++;
    }
  }
  return null;
}

/// Split a cloze's inner content into (text, hint) on the FIRST top-level `::`
/// — Anki's rule (its regex matches the answer non-greedily, so the hint is
/// everything after the first separator, `::` and all). `::` inside nested
/// braces is ignored via single-brace depth.
(String, String?) _splitHint(String inner) {
  var depth = 0;
  var i = 0;
  while (i < inner.length) {
    final ch = inner.codeUnitAt(i);
    if (ch == 0x7b) {
      depth++;
      i++;
    } else if (ch == 0x7d) {
      if (depth > 0) depth--;
      i++;
    } else if (depth == 0 &&
        ch == 0x3a &&
        i + 1 < inner.length &&
        inner.codeUnitAt(i + 1) == 0x3a) {
      return (inner.substring(0, i), inner.substring(i + 2));
    } else {
      i++;
    }
  }
  return (inner, null);
}

bool _listEquals(List<ClozeNode> a, List<ClozeNode> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _short(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

// ── Small LRU memo (mirrors parseInlineHtmlCached) ─────────────────────────

const int _cacheCap = 50;
final Map<String, List<ClozeNode>> _cache = {};

/// Parse with a tiny LRU keyed by (cardId, face). Null [cacheKey] parses
/// uncached (tests / one-off renders).
List<ClozeNode> parseClozeCached(String s, {String? cacheKey}) {
  if (cacheKey == null) return parseCloze(s);
  final hit = _cache.remove(cacheKey);
  if (hit != null) {
    _cache[cacheKey] = hit;
    return hit;
  }
  final parsed = parseCloze(s);
  _cache[cacheKey] = parsed;
  if (_cache.length > _cacheCap) {
    _cache.remove(_cache.keys.first);
  }
  return parsed;
}

/// Visible for tests: reset the memo so cache assertions are deterministic.
void debugClearClozeCache() => _cache.clear();

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/domain/cloze.dart';

/// Flatten a node tree into a readable string for assertions:
/// plain text verbatim, a deletion as `⟦cN:…|hint⟧`.
String _flat(List<ClozeNode> nodes) {
  final buf = StringBuffer();
  for (final n in nodes) {
    switch (n) {
      case ClozeText(:final text):
        buf.write(text);
      case ClozeDeletion(:final index, :final content, :final hint):
        buf.write('⟦c$index:${_flat(content)}');
        if (hint != null) buf.write('|$hint');
        buf.write('⟧');
    }
  }
  return buf.toString();
}

List<ClozeDeletion> _deletions(List<ClozeNode> nodes) {
  final out = <ClozeDeletion>[];
  for (final n in nodes) {
    if (n is ClozeDeletion) {
      out.add(n);
      out.addAll(_deletions(n.content));
    }
  }
  return out;
}

void main() {
  group('isCloze', () {
    test('detects openers, ignores plain / braces', () {
      expect(isCloze('{{c1::x}} rest'), isTrue);
      expect(isCloze('{{c12::x}}'), isTrue);
      expect(isCloze('plain text'), isFalse);
      expect(isCloze('a {b} c'), isFalse);
      expect(isCloze('{{cloze}} not a deletion'), isFalse); // no ::/index
    });
  });

  group('parseCloze — basics', () {
    test('single cloze between plain text', () {
      final nodes = parseCloze('The {{c1::mitochondria}} is the powerhouse.');
      expect(_flat(nodes), 'The ⟦c1:mitochondria⟧ is the powerhouse.');
      final d = _deletions(nodes).single;
      expect(d.index, 1);
      expect(d.hint, isNull);
    });

    test('multiple clozes with different indices', () {
      final nodes = parseCloze('{{c1::a}} and {{c2::b}} and {{c3::c}}');
      expect(_flat(nodes), '⟦c1:a⟧ and ⟦c2:b⟧ and ⟦c3:c⟧');
      expect(_deletions(nodes).map((d) => d.index), [1, 2, 3]);
    });

    test('hint after the first top-level ::', () {
      final nodes = parseCloze('{{c1::answer::the hint}}');
      final d = _deletions(nodes).single;
      expect(_flat(d.content), 'answer');
      expect(d.hint, 'the hint');
    });

    test('empty hint collapses to null', () {
      final d = _deletions(parseCloze('{{c1::x::}}')).single;
      expect(d.hint, isNull);
    });

    test('splits at the FIRST ::; the hint keeps any later ::', () {
      // Anki matches the answer non-greedily, so the hint is everything after
      // the first separator.
      final d = _deletions(parseCloze('{{c1::a::b::c}}')).single;
      expect(_flat(d.content), 'a');
      expect(d.hint, 'b::c');

      final d2 = _deletions(
        parseCloze('{{c1::orbits::this hint has "::" in it}}'),
      ).single;
      expect(_flat(d2.content), 'orbits');
      expect(d2.hint, 'this hint has "::" in it');
    });

    test('multi-digit cloze index', () {
      final d = _deletions(parseCloze('{{c12::x}}')).single;
      expect(d.index, 12);
    });

    test('shared/multi-card ordinal list (c1,2) is a cloze', () {
      expect(isCloze('{{c1,2::shared}}'), isTrue);
      final d = _deletions(parseCloze('a {{c1,2::shared}} b')).single;
      expect(_flat(d.content), 'shared');
      expect(d.index, 1); // first ordinal (index is irrelevant in fallback mode)
    });
  });

  group('parseCloze — nesting', () {
    test('brace-balances to the correct closing braces', () {
      final nodes = parseCloze('{{c1::a {{c2::b}} c}}');
      // One top-level deletion c1 whose content holds the nested c2.
      expect(nodes.whereType<ClozeDeletion>().length, 1);
      final c1 = nodes.whereType<ClozeDeletion>().single;
      expect(c1.index, 1);
      expect(_flat(c1.content), 'a ⟦c2:b⟧ c');
      final c2 = c1.content.whereType<ClozeDeletion>().single;
      expect(c2.index, 2);
      expect(_flat(c2.content), 'b');
    });

    test('content ending in a balanced brace keeps it inside the deletion', () {
      // Regression: unified single-brace depth must keep the content's trailing
      // "}" inside the deletion, not leak it out after the pill.
      final nodes = parseCloze(r'{{c1::set is \{a, b\}}}');
      expect(nodes.whereType<ClozeText>(), isEmpty); // no stray trailing "}"
      final d = _deletions(nodes).single;
      expect(d.index, 1);
      expect(_flat(d.content), r'set is \{a, b\}');
    });

    test('balanced LaTeX / JSON braces stay inside the deletion', () {
      expect(_flat(_deletions(parseCloze(r'{{c1::\frac{a}{b}}}')).single.content),
          r'\frac{a}{b}');
      expect(_flat(_deletions(parseCloze('{{c1::{"k": 1}}}')).single.content),
          '{"k": 1}');
    });

    test('an unbalanced lone } in content is kept, not dropped', () {
      // Regression: the close is the literal }} at content depth 0, so a lone
      // '}' before it stays inside the deletion (no character loss / stray '}').
      final a = parseCloze('{{c1::a } b}}');
      expect(a.whereType<ClozeText>(), isEmpty); // no leaked trailing brace
      expect(_flat(_deletions(a).single.content), 'a } b');

      final b = parseCloze('{{c1::the closing } of a block}}');
      expect(_flat(_deletions(b).single.content), 'the closing } of a block');
    });

    test('a lone { with no match renders literally (never drops text)', () {
      final nodes = parseCloze('{{c1::a { b}}');
      expect(_flat(nodes), '{{c1::a { b}}'); // literal, all text preserved
    });
  });

  group('parseCloze — malformed never throws, renders literally', () {
    test('unclosed opener passes through as literal text', () {
      final nodes = parseCloze('{{c1::mitochondria');
      expect(nodes, [const ClozeText('{{c1::mitochondria')]);
    });

    test('opener with no closing braces mid-string stays literal', () {
      final nodes = parseCloze('before {{c1::x after');
      expect(_flat(nodes), 'before {{c1::x after');
      expect(_deletions(nodes), isEmpty);
    });

    test('a valid cloze after an unclosable one still parses', () {
      // c1 never finds its own literal }} (only c2's does), so the c1 opener is
      // literal and the inner c2 is the one real deletion. No throw, no loss.
      final nodes = parseCloze('{{c1::open and {{c2::closed}}');
      expect(_flat(nodes), '{{c1::open and ⟦c2:closed⟧');
      final d = _deletions(nodes).single;
      expect(d.index, 2);
      expect(_flat(d.content), 'closed');
    });

    test('stray braces are literal', () {
      expect(parseCloze('a }} b {{ c'), [const ClozeText('a }} b {{ c')]);
    });

    test('empty input', () {
      expect(parseCloze(''), isEmpty);
    });

    test('a pathological long-digit index is not a cloze (literal, no throw)', () {
      // The ≤9-digit opener bound rejects a 20-digit run identically on native
      // and web (dart2js) — it renders literally instead of overflowing int64
      // on one platform and parsing on the other.
      const s = '{{c99999999999999999999::x}} tail';
      expect(() => parseCloze(s), returnsNormally);
      expect(isCloze(s), isFalse);
      expect(_deletions(parseCloze(s)), isEmpty);
      expect(_flat(parseCloze(s)), s);
    });
  });

  group('parseCloze — HTML / math survive inside content', () {
    test('HTML tags are kept raw in the content for the downstream pipeline', () {
      final d = _deletions(parseCloze('{{c1::<b>bold</b>}}')).single;
      expect(_flat(d.content), '<b>bold</b>');
    });

    test('inline math delimiters survive', () {
      final d = _deletions(parseCloze(r'{{c1::\(x=5\)}}')).single;
      expect(_flat(d.content), r'\(x=5\)');
    });

    test('plain segments keep their HTML (br between clozes)', () {
      final nodes = parseCloze('1. {{c1::a}}<br>2. {{c2::b}}');
      expect(_flat(nodes), '1. ⟦c1:a⟧<br>2. ⟦c2:b⟧');
    });
  });

  group('parseClozeCached', () {
    test('returns identical instance on a cache hit', () {
      debugClearClozeCache();
      final a = parseClozeCached('{{c1::x}}', cacheKey: '1:front');
      final b = parseClozeCached('{{c1::x}}', cacheKey: '1:front');
      expect(identical(a, b), isTrue);
    });

    test('null cacheKey never caches', () {
      final a = parseClozeCached('{{c1::x}}');
      final b = parseClozeCached('{{c1::x}}');
      expect(identical(a, b), isFalse);
    });
  });
}

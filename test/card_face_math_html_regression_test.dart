// Synthetic fields only; no services, stored cards, or personal data.
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';

Widget _host(String html, {bool revealed = false}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 320,
      child: CardFace(
        html: html,
        hasLatex: true,
        revealCloze: revealed,
        cacheKey: 'synthetic:math-html',
        style: const TextStyle(fontSize: 18),
      ),
    ),
  ),
);

List<Map<String, Object?>> _mathNodes(Iterable<Math> maths) => [
  for (final math in maths)
    for (final node in math.ast!.greenRoot.children) node.toJson(),
];

void _expectMath(WidgetTester tester, List<String> expressions) {
  final maths = tester.widgetList<Math>(find.byType(Math)).toList();
  expect(maths, isNotEmpty);
  expect(maths.every((math) => math.parseError == null), isTrue);
  // Parse success alone would also accept a silently shortened expression.
  expect(_mathNodes(maths), _mathNodes(expressions.map(Math.tex)));
  expect(tester.takeException(), isNull);
}

void main() {
  for (final delimiters in [
    (open: r'\(', close: r'\)', style: MathStyle.text),
    (open: r'\[', close: r'\]', style: MathStyle.display),
    (open: r'$$', close: r'$$', style: MathStyle.display),
  ]) {
    testWidgets('inequality hint survives HTML: ${delimiters.open}', (
      tester,
    ) async {
      final hint = '${delimiters.open}a<b, c>d${delimiters.close}';
      final html = '{{c1::synthetic answer::$hint}}';
      await tester.pumpWidget(_host(html));

      _expectMath(tester, ['a<b, c>d']);
      expect(
        tester
            .widgetList<Math>(find.byType(Math))
            .map((math) => math.mathStyle),
        everyElement(delimiters.style),
      );
      final label = tester.widget<Text>(find.textContaining('['));
      expect(label.textSpan!.toPlainText(), startsWith('['));
      expect(label.textSpan!.toPlainText(), endsWith(']'));
      expect(label.textSpan!.toPlainText(), isNot(contains(hint)));
      expect(find.textContaining('synthetic answer'), findsNothing);

      // Reuse the mounted/cached face to check that reveal removes the hint.
      await tester.pumpWidget(_host(html, revealed: true));
      expect(find.textContaining('synthetic answer'), findsOneWidget);
      expect(find.byType(Math), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('HTML and entities around multiple math hints retain styling', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        r'{{c1::synthetic answer::<b>A &amp; B \(a<b, c>d\)</b>'
        r'<br><i>next</i> \[x<y, z>w\]}}',
      ),
    );
    _expectMath(tester, ['a<b, c>d', 'x<y, z>w']);
    final hint = tester.widget<Text>(find.textContaining('A & B'));
    final spans = <TextSpan>[];
    hint.textSpan!.visitChildren((span) {
      if (span is TextSpan) spans.add(span);
      return true;
    });
    expect(
      spans.singleWhere((span) => span.text == 'A & B ').style?.fontWeight,
      FontWeight.w700,
    );
    expect(
      spans.singleWhere((span) => span.text == 'next').style?.fontStyle,
      FontStyle.italic,
    );
    expect(hint.textSpan!.toPlainText(), contains('\n'));
    expect(hint.textSpan!.toPlainText(), isNot(contains('<b>')));
    for (final math in tester.widgetList<Math>(find.byType(Math))) {
      expect(math.textStyle?.color, hint.textSpan!.style?.color);
    }
  });

  testWidgets('entity-encoded inequalities in hints are decoded once', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(r'{{c1::synthetic answer::\(a&lt;b, c&gt;d\)}}'),
    );
    _expectMath(tester, ['a<b, c>d']);
  });

  for (final revealed in [false, true]) {
    testWidgets('math survives HTML in ${revealed ? 'answer' : 'plain face'}', (
      tester,
    ) async {
      const content = r'<b>bounds</b> \(a<b, c>d\)';
      await tester.pumpWidget(
        _host(
          revealed ? '{{c1::$content::synthetic hint}}' : content,
          revealed: revealed,
        ),
      );
      _expectMath(tester, ['a<b, c>d']);
      expect(find.textContaining('bounds'), findsOneWidget);
      expect(find.textContaining('synthetic hint'), findsNothing);
    });
  }
}

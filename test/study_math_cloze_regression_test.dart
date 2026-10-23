// Invented fields only; all rendering stays inside the widget test process.
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';

Widget _host(String html, {bool revealed = false, double width = 280}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: CardFace(
              html: html,
              hasLatex: true,
              revealCloze: revealed,
              cacheKey: 'synthetic:front',
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );

// Compare the actual rendered math tree with the package's unsplit TeX tree.
// Checking only parseError would miss a valid but different formula (dot + s).
List<Map<String, Object?>> _mathNodes(Iterable<Math> maths) => [
  for (final math in maths)
    for (final node in math.ast!.greenRoot.children) node.toJson(),
];

void main() {
  for (final expression in [r'a\cdots z', r'x\pmod{n}', r'x\intop_0^1 f']) {
    testWidgets('line breaking preserves the complete macro $expression', (
      tester,
    ) async {
      final expected = Math.tex(expression);
      expect(expected.parseError, isNull);
      await tester.pumpWidget(_host('\\($expression\\)'));
      final maths = tester.widgetList<Math>(find.byType(Math)).toList();
      expect(maths, isNotEmpty);
      expect(maths.every((math) => math.parseError == null), isTrue);
      expect(_mathNodes(maths), _mathNodes([expected]));
      expect(tester.takeException(), isNull);
    });
  }

  for (final expression in [
    (source: r'\left.x\right|', visible: r'x|'),
    (source: r'\left|x\right.', visible: r'|x'),
    (source: r'\left.x\right.', visible: r'x'),
    (source: r'\left .x\right .', visible: r'x'),
  ]) {
    testWidgets('invisible delimiters stay invisible: ${expression.source}', (
      tester,
    ) async {
      await tester.pumpWidget(_host('\\(${expression.source}\\)'));
      final maths = tester.widgetList<Math>(find.byType(Math)).toList();
      expect(maths, isNotEmpty);
      expect(maths.every((math) => math.parseError == null), isTrue);
      expect(_mathNodes(maths), _mathNodes([Math.tex(expression.visible)]));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cloze hint decodes entities and renders HTML and math', (
    tester,
  ) async {
    const html = r'{{c1::synthetic answer::<b>A &amp; B</b> \(x^2\)}}';
    await tester.pumpWidget(_host(html));
    expect(find.textContaining('synthetic answer'), findsNothing);
    final hint = tester.widget<Text>(find.textContaining('A & B'));
    expect(hint.textSpan!.toPlainText(), isNot(contains('<b>')));
    final bold = <TextSpan>[];
    hint.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.text == 'A & B') bold.add(span);
      return true;
    });
    expect(bold.single.style?.fontWeight, FontWeight.w700);
    final maths = tester.widgetList<Math>(find.byType(Math)).toList();
    expect(_mathNodes(maths), _mathNodes([Math.tex('x^2')]));
    expect(maths.single.textStyle?.color, hint.textSpan!.style?.color);
    expect(tester.takeException(), isNull);

    // The same mounted/cached face must reveal the answer and remove its hint.
    await tester.pumpWidget(_host(html, revealed: true));
    expect(find.textContaining('synthetic answer'), findsOneWidget);
    expect(find.textContaining('A & B'), findsNothing);
    expect(find.byType(Math), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

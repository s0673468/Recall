import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: SizedBox(width: 320, child: child))),
);

void main() {
  group('CardFace rich HTML', () {
    testWidgets('renders bold text as a weighted span', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'a <b>heavy</b> b',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
          ),
        ),
      );
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      final span = selectable.textSpan!;
      expect(span.toPlainText(), 'a heavy b');
      // Find the "heavy" child and confirm it is bold.
      InlineSpan? heavy;
      span.visitChildren((s) {
        if (s is TextSpan && s.text == 'heavy') heavy = s;
        return true;
      });
      expect((heavy as TextSpan?)?.style?.fontWeight, FontWeight.w700);
      expect(tester.takeException(), isNull);
    });

    testWidgets('absolute https <img> renders an Image', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'see <img src="https://x.test/a.png"> here',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
          ),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('relative <img> shows a "media not synced" chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'x <img src="paste.jpg"> y',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
          ),
        ),
      );
      expect(find.text('media not synced'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-cloze/non-HTML card is byte-identical plain text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'What is backprop?',
            hasLatex: false,
            style: TextStyle(),
          ),
        ),
      );
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), 'What is backprop?');
      expect(tester.takeException(), isNull);
    });
  });

  group('CardFace latex_svg fallback', () {
    testWidgets('display-math face with latex_svg renders the SVG', (
      tester,
    ) async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
          '<rect width="10" height="10"/></svg>';
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: r'\[ E = mc^2 \]',
            hasLatex: true,
            latexSvg: svg,
            style: TextStyle(fontSize: 18, color: Colors.white),
          ),
        ),
      );
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('display math with no SVG falls back to literal text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: r'\[ E = mc^2 \]',
            hasLatex: true,
            style: TextStyle(fontSize: 18),
          ),
        ),
      );
      expect(find.byType(SvgPicture), findsNothing);
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), contains('E = mc^2'));
      expect(tester.takeException(), isNull);
    });
  });

  group('CardFace cloze', () {
    testWidgets('front hides the deletion, keeps surrounding text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'The {{c1::mitochondria}} is the powerhouse.',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
            revealCloze: false,
          ),
        ),
      );
      expect(find.textContaining('mitochondria'), findsNothing); // hidden
      expect(find.textContaining('powerhouse'), findsOneWidget); // plain kept
      expect(find.textContaining('…'), findsOneWidget); // the [ … ] pill
      expect(tester.takeException(), isNull);
    });

    testWidgets('back reveals the deletion in a pill', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'The {{c1::mitochondria}} is the powerhouse.',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
            revealCloze: true,
          ),
        ),
      );
      expect(find.textContaining('mitochondria'), findsOneWidget); // revealed
      expect(tester.takeException(), isNull);
    });

    testWidgets('front shows the hint instead of the answer', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'ATP is {{c1::adenosine triphosphate::energy molecule}}.',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
            revealCloze: false,
          ),
        ),
      );
      expect(find.textContaining('energy molecule'), findsOneWidget); // hint
      expect(find.textContaining('adenosine'), findsNothing); // answer hidden
      expect(tester.takeException(), isNull);
    });

    testWidgets('all deletions hidden on front (fallback all-cloze mode)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'axes: {{c1::parameters}}, {{c2::training time}}, '
                '{{c3::dataset size}}',
            hasLatex: false,
            style: TextStyle(fontSize: 16),
            revealCloze: false,
          ),
        ),
      );
      for (final answer in ['parameters', 'training time', 'dataset size']) {
        expect(find.textContaining(answer), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('cloze composes with inline math on the front', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: r'The {{c1::derivative}} of \(x^2\) is \(2x\).',
            hasLatex: true,
            style: TextStyle(fontSize: 18),
            revealCloze: false,
          ),
        ),
      );
      expect(find.textContaining('derivative'), findsNothing); // cloze hidden
      expect(find.byType(Math), findsWidgets); // math still rendered
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed cloze renders literally, never throws', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'unclosed {{c1::mito and more text',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
            revealCloze: false,
          ),
        ),
      );
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), contains('{{c1::mito'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('back reveals every deletion of a multi-cloze face', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'axes: {{c1::parameters}}, {{c2::training time}}, '
                '{{c3::dataset size}}',
            hasLatex: false,
            style: TextStyle(fontSize: 16),
            revealCloze: true,
          ),
        ),
      );
      for (final answer in ['parameters', 'training time', 'dataset size']) {
        expect(find.textContaining(answer), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a <br> next to a deletion survives (line break kept)', (
      tester,
    ) async {
      // Note 507's shape: block breaks interleaved with clozes. Per-segment
      // HTML parsing must not trim the boundary <br>.
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: '1. {{c1::a}}<br>2. {{c2::b}}<br>3. {{c3::c}}',
            hasLatex: false,
            style: TextStyle(fontSize: 16),
            revealCloze: false,
          ),
        ),
      );
      final plain = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText();
      expect('\n'.allMatches(plain).length, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('revealed pill keeps inner bold styling', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: 'The {{c1::<b>powerhouse</b>}} of the cell.',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
            revealCloze: true,
          ),
        ),
      );
      InlineSpan? bold;
      void visit(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text == 'powerhouse' && s.style?.fontWeight == FontWeight.w700) {
            bold = s;
          }
          s.children?.forEach(visit);
        }
      }

      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final span = t.textSpan;
        if (span != null) visit(span);
      }
      expect(bold, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('documents: HTML straddling a deletion does not carry across', (
      tester,
    ) async {
      // Known, accepted limitation: each plain segment is HTML-parsed
      // independently, so <b> opened before a deletion and closed after it only
      // bolds the leading segment. Real cards don't wrap formatting around a
      // deletion. This test pins the current behavior so a change is deliberate.
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: '<b>bold before {{c1::x}} bold after</b>',
            hasLatex: false,
            style: TextStyle(fontSize: 18),
            revealCloze: false,
          ),
        ),
      );
      FontWeight? weightOf(String text) {
        FontWeight? found;
        void visit(InlineSpan s) {
          if (s is TextSpan) {
            if ((s.text ?? '').contains(text)) found = s.style?.fontWeight;
            s.children?.forEach(visit);
          }
        }

        visit(
          tester
              .widget<SelectableText>(find.byType(SelectableText))
              .textSpan!,
        );
        return found;
      }

      expect(weightOf('bold before'), FontWeight.w700);
      expect(weightOf('bold after'), isNot(FontWeight.w700)); // not carried
      expect(tester.takeException(), isNull);
    });

    testWidgets('revealed pill renders inner inline math', (tester) async {
      await tester.pumpWidget(
        _host(
          const CardFace(
            html: r'The area is {{c1::\(\pi r^2\)}}.',
            hasLatex: true,
            style: TextStyle(fontSize: 18),
            revealCloze: true,
          ),
        ),
      );
      expect(find.byType(Math), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('ReviewCard.latexSvg snapshot compatibility', () {
    test('old snapshot JSON without latex_svg still loads', () {
      final card = ReviewCard.fromJson({
        'id': 1,
        'guid': 'g1',
        'deck_id': 1,
        'front': 'f',
        'back': 'b',
        'has_latex': false,
        'stability': 1.0,
        'difficulty': 1.0,
        'due': null,
        'state': 0,
        'reps': 0,
        'lapses': 0,
        'last_review': null,
      });
      expect(card.latexSvg, isNull);
    });

    test('round-trips latexSvg when present', () {
      final card = ReviewCard.fromJson({
        'id': 2,
        'guid': 'g2',
        'deck_id': 1,
        'front': 'f',
        'back': 'b',
        'has_latex': true,
        'state': 0,
        'reps': 0,
        'lapses': 0,
        'latex_svg': '<svg/>',
      });
      expect(card.latexSvg, '<svg/>');
      expect(card.toJson()['latex_svg'], '<svg/>');
    });

    test('jsonb map/list latex_svg is coerced to the first svg string', () {
      final card = ReviewCard.fromRow({
        'id': 3,
        'guid': 'g3',
        'state': 0,
        'reps': 0,
        'lapses': 0,
        'notes': {
          'deck_id': 1,
          'front': 'f',
          'back': 'b',
          'has_latex': true,
          'latex_svg': {'0': '<svg id="a"/>'},
        },
      });
      expect(card.latexSvg, '<svg id="a"/>');
    });
  });
}

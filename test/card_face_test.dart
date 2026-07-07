import 'package:flutter/material.dart';
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

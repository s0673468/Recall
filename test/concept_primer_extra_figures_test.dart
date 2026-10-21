import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/primer_layout.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" '
    'viewBox="0 0 600 360"><rect width="600" height="360"/></svg>';

ConceptExtraFigure _fig(int? after, [String svg = _svg]) =>
    ConceptExtraFigure(svg: svg, afterParagraph: after);

List<Object> _shape(List<PrimerBlock> blocks) => [
  for (final block in blocks)
    switch (block) {
      PrimerTextBlock(:final html) => html,
      PrimerFigureBlock(:final index) => index,
    },
];

void main() {
  group('ConceptExtraFigure.parseList', () {
    test('parses valid figures in array order', () {
      final figures = ConceptExtraFigure.parseList([
        {'svg': _svg, 'after_paragraph': 2},
        {'svg': '  \n<svg viewBox="0 0 600 360"></svg>', 'after_paragraph': 1},
      ]);
      expect(figures, hasLength(2));
      expect(figures[0].svg, _svg);
      expect(figures[0].afterParagraph, 2);
      expect(figures[1].afterParagraph, 1);
    });

    test('null or a non-array value yields no figures', () {
      for (final raw in <Object?>[
        null,
        '[]',
        {'svg': _svg, 'after_paragraph': 1},
        42,
        jsonEncode([
          {'svg': _svg},
        ]),
      ]) {
        expect(ConceptExtraFigure.parseList(raw), isEmpty, reason: '$raw');
      }
    });

    test('skips elements without a string svg starting with <svg', () {
      final figures = ConceptExtraFigure.parseList([
        'not an object',
        null,
        7,
        <Object>[_svg],
        {'after_paragraph': 1},
        {'svg': null, 'after_paragraph': 1},
        {'svg': 12, 'after_paragraph': 1},
        {'svg': '<div>not svg</div>', 'after_paragraph': 1},
        {'svg': '<SVG viewBox="0 0 600 360"/>', 'after_paragraph': 1},
        {'svg': _svg, 'after_paragraph': 3},
      ]);
      expect(figures, hasLength(1));
      expect(figures.single.afterParagraph, 3);
    });

    test('a missing or invalid after_paragraph places it after the body', () {
      final figures = ConceptExtraFigure.parseList([
        {'svg': _svg},
        {'svg': _svg, 'after_paragraph': 0},
        {'svg': _svg, 'after_paragraph': -2},
        {'svg': _svg, 'after_paragraph': '2'},
        {'svg': _svg, 'after_paragraph': 2.5},
        {'svg': _svg, 'after_paragraph': null},
      ]);
      // Capped at three; every kept one lands after the body.
      expect(figures, hasLength(3));
      expect(figures.map((f) => f.afterParagraph), [null, null, null]);
    });

    test('keeps only the first three valid figures', () {
      final figures = ConceptExtraFigure.parseList([
        {'svg': 'bad', 'after_paragraph': 9},
        for (var k = 1; k <= 5; k++) {'svg': _svg, 'after_paragraph': k},
      ]);
      expect(figures.map((f) => f.afterParagraph), [1, 2, 3]);
    });
  });

  group('splitTopLevelParagraphs', () {
    test('splits on <br><br> case-insensitively with any whitespace', () {
      expect(splitTopLevelParagraphs('One.<br><br>Two.<BR>\n  <Br>Three.'), [
        'One.',
        'Two.',
        'Three.',
      ]);
    });

    test('a single <br> or no break keeps one paragraph', () {
      expect(splitTopLevelParagraphs('One.<br>Still one.'), [
        'One.<br>Still one.',
      ]);
      expect(splitTopLevelParagraphs(''), ['']);
    });

    test('never splits inside bold, code, or a list', () {
      const body =
          'Intro <b>bold<br><br>still bold</b>.<br><br>'
          '<ul><li>a<br><br>b</li><li>c</li></ul><br><br>'
          '<code>x<br><br>y</code> end';
      expect(splitTopLevelParagraphs(body), [
        'Intro <b>bold<br><br>still bold</b>.',
        '<ul><li>a<br><br>b</li><li>c</li></ul>',
        '<code>x<br><br>y</code> end',
      ]);
    });

    test('a stray closing tag does not hide later breaks', () {
      expect(splitTopLevelParagraphs('a</b><br><br>b'), ['a</b>', 'b']);
    });

    test('an unclosed tag keeps the rest as one paragraph', () {
      expect(splitTopLevelParagraphs('a<br><br><i>b<br><br>c'), [
        'a',
        '<i>b<br><br>c',
      ]);
    });

    test('a trailing break counts an empty last paragraph', () {
      expect(splitTopLevelParagraphs('a<br><br>b<br><br>'), ['a', 'b', '']);
    });
  });

  group('layoutPrimerBody', () {
    const body = 'P1<br><br>P2<br>\n<br>P3';

    test('no figures returns the untouched body as one block', () {
      expect(_shape(layoutPrimerBody(body, const [])), [body]);
    });

    test('a figure follows paragraph k', () {
      expect(_shape(layoutPrimerBody(body, [_fig(1)])), [
        'P1',
        0,
        'P2<br>\n<br>P3',
      ]);
      expect(_shape(layoutPrimerBody(body, [_fig(2)])), [
        'P1<br><br>P2',
        0,
        'P3',
      ]);
    });

    test('k at or beyond the paragraph count, or null, goes after body', () {
      for (final after in [3, 4, 99, null]) {
        expect(_shape(layoutPrimerBody(body, [_fig(after)])), [
          body,
          0,
        ], reason: 'after_paragraph $after');
      }
    });

    test('figures sharing k keep array order', () {
      expect(_shape(layoutPrimerBody(body, [_fig(2), _fig(1), _fig(2)])), [
        'P1',
        1,
        'P2',
        0,
        2,
        'P3',
      ]);
    });

    test('an empty trailing paragraph renders no text block', () {
      expect(_shape(layoutPrimerBody('A<br><br>B<br><br>', [_fig(2)])), [
        'A<br><br>B',
        0,
      ]);
    });

    test('paragraph numbering ignores breaks inside a list', () {
      const listBody = 'Intro<br><br><ol><li>a<br><br>b</li></ol><br><br>End';
      expect(_shape(layoutPrimerBody(listBody, [_fig(2)])), [
        'Intro<br><br><ol><li>a<br><br>b</li></ol>',
        0,
        'End',
      ]);
    });
  });

  group('PrimerScreen extra figures', () {
    const node = ConceptNodeInfo(
      nodeId: 'm00-vector-geometry',
      title: 'Vector geometry',
      module: 'M00',
    );
    const bodyHtml =
        'Alpha paragraph text.<br><br>'
        'Beta paragraph text.<br><br>'
        'Gamma paragraph text.';

    Future<void> pump(WidgetTester tester, ConceptPage page) async {
      tester.view.physicalSize = const Size(390, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: PrimerScreen(page: page, conceptNodes: const [node]),
        ),
      );
      await tester.pumpAndSettle();
    }

    double top(WidgetTester tester, Finder finder) =>
        tester.getTopLeft(finder).dy;

    Finder extra(int index) => find.byKey(
      ValueKey('recall_primer_extra_figure_${node.nodeId}_$index'),
    );

    List<String?> cacheKeys(WidgetTester tester) => [
      for (final face in tester.widgetList<CardFace>(find.byType(CardFace)))
        face.cacheKey,
    ];

    testWidgets('figures appear in order between the right paragraphs', (
      tester,
    ) async {
      await pump(
        tester,
        ConceptPage(
          nodeId: node.nodeId,
          title: 'Vector geometry primer',
          bodyHtml: bodyHtml,
          figureSvg: _svg,
          extraFigures: [_fig(2), _fig(1), _fig(null)],
          updatedAt: DateTime.utc(2026, 10, 21),
        ),
      );

      final hero = top(
        tester,
        find.byKey(ValueKey('recall_primer_figure_${node.nodeId}')),
      );
      final alpha = top(tester, find.textContaining('Alpha'));
      final beta = top(tester, find.textContaining('Beta'));
      final gamma = top(tester, find.textContaining('Gamma'));
      final afterAlpha = top(tester, extra(1));
      final afterBeta = top(tester, extra(0));
      final afterBody = top(tester, extra(2));

      expect(hero, lessThan(alpha));
      expect(alpha, lessThan(afterAlpha));
      expect(afterAlpha, lessThan(beta));
      expect(beta, lessThan(afterBeta));
      expect(afterBeta, lessThan(gamma));
      expect(gamma, lessThan(afterBody));
      expect(find.byType(SvgPicture), findsNWidgets(4));

      // Same box as the hero figure: full width at the 600/360 ratio.
      final heroSize = tester.getSize(
        find.byKey(ValueKey('recall_primer_figure_${node.nodeId}')),
      );
      expect(tester.getSize(extra(0)), heroSize);
      expect(heroSize.width / heroSize.height, closeTo(600 / 360, 0.01));

      expect(cacheKeys(tester), [
        'primer:${node.nodeId}:0',
        'primer:${node.nodeId}:1',
        'primer:${node.nodeId}:2',
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without extra figures the body is one unchanged CardFace', (
      tester,
    ) async {
      await pump(
        tester,
        ConceptPage(
          nodeId: node.nodeId,
          title: 'Vector geometry primer',
          bodyHtml: bodyHtml,
          figureSvg: _svg,
          updatedAt: DateTime.utc(2026, 10, 21),
        ),
      );

      expect(cacheKeys(tester), ['primer:${node.nodeId}']);
      expect(tester.widget<CardFace>(find.byType(CardFace)).html, bodyHtml);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(extra(0), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a malformed extra figure never breaks the page', (
      tester,
    ) async {
      await pump(
        tester,
        ConceptPage(
          nodeId: node.nodeId,
          title: 'Malformed extra figure',
          bodyHtml: bodyHtml,
          extraFigures: [_fig(1, '<svg><not-closed>')],
          updatedAt: DateTime.utc(2026, 10, 21),
        ),
      );

      expect(find.textContaining('Alpha'), findsOneWidget);
      expect(find.textContaining('Gamma'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('RecallApi.fetchConceptPages extra figures', () {
    SupabaseClient clientFor(
      List<Uri> requests,
      http.Response Function(http.Request request, int call) respond,
    ) {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return respond(request, requests.length);
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      return client;
    }

    http.Response json(http.Request request, Object body, [int status = 200]) =>
        http.Response(
          jsonEncode(body),
          status,
          request: request,
          headers: {'content-type': 'application/json'},
        );

    Map<String, Object?> row({Object? extraFigures = const <Object>[]}) => {
      'node_id': 'm00-vector-geometry',
      'title': 'Vector geometry',
      'body_html': 'One.<br><br>Two.',
      'figure_svg': _svg,
      'extra_figures': ?extraFigures,
      'updated_at': '2026-10-21T12:00:00.000Z',
    };

    test('parses extra_figures from the full select', () async {
      final requests = <Uri>[];
      final client = clientFor(
        requests,
        (request, _) => json(request, [
          row(
            extraFigures: [
              {'svg': _svg, 'after_paragraph': 1},
              {'svg': 'not svg', 'after_paragraph': 1},
            ],
          ),
        ]),
      );

      final pages = await RecallApi(client).fetchConceptPages();

      expect(requests, hasLength(1));
      expect(
        requests.single.queryParameters['select'],
        'node_id,title,body_html,figure_svg,extra_figures,updated_at',
      );
      expect(pages.single.extraFigures, hasLength(1));
      expect(pages.single.extraFigures.single.afterParagraph, 1);
    });

    test(
      'retries the pre-009 select once when the column is missing',
      () async {
        final requests = <Uri>[];
        final client = clientFor(
          requests,
          (request, call) => call == 1
              ? json(request, {
                  'code': '42703',
                  'message':
                      'column concept_pages.extra_figures does not exist',
                  'details': null,
                  'hint': null,
                }, 400)
              : json(request, [row(extraFigures: null)]),
        );

        final pages = await RecallApi(client).fetchConceptPages();

        expect(requests.map((uri) => uri.queryParameters['select']), [
          'node_id,title,body_html,figure_svg,extra_figures,updated_at',
          'node_id,title,body_html,figure_svg,updated_at',
        ]);
        expect(pages, hasLength(1));
        expect(pages.single.bodyHtml, 'One.<br><br>Two.');
        expect(pages.single.extraFigures, isEmpty);
      },
    );

    test('returns empty after the single retry also fails', () async {
      final requests = <Uri>[];
      final client = clientFor(
        requests,
        (request, _) => json(request, {
          'code': '42P01',
          'message': 'relation "public.concept_pages" does not exist',
          'details': null,
          'hint': null,
        }, 404),
      );

      await expectLater(
        RecallApi(client).fetchConceptPages(),
        completion(isEmpty),
      );
      expect(requests, hasLength(2));
    });
  });
}

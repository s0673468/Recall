import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/card_back.dart';
import 'package:health_anki_flutter/features/review/domain/concept_attribution.dart';
import 'package:health_anki_flutter/features/review/domain/primer_layout.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

ConceptPage page(String id, {String body = 'Synthetic explanation'}) =>
    ConceptPage(
      nodeId: id,
      title: 'Synthetic $id',
      bodyHtml: body,
      updatedAt: DateTime.utc(2026, 11, 1),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('reading sections', () {
    test('unknown, misspelled and non-leading labels stay ordinary text', () {
      for (final paragraph in [
        '<b>Unknown.</b> Text',
        '<b>In shorts.</b> Text',
        'Before <b>In short.</b> Text',
        '<i><b>In short.</b></i> Text',
      ]) {
        expect(primerSectionOpening(paragraph), isNull, reason: paragraph);
      }
    });

    test(
      'recognizes every agreed label and straight, curly and entity apostrophes',
      () {
        for (final label in [
          'In short.',
          'Picture it.',
          'How it works.',
          'The formula.',
          'Worked example.',
          'Compare.',
          'Watch out.',
          "Where you'll meet it.",
          'Where you’ll meet it.',
          'Where you&rsquo;ll meet it.',
          'Where you&#39;ll meet it.',
          'Where you&#x2019;ll meet it.',
        ]) {
          final opening = primerSectionOpening(
            '  <b>$label</b> Remaining <i>text</i>',
          );
          expect(opening, isNotNull, reason: label);
          expect(opening!.html, 'Remaining <i>text</i>');
          expect(opening.heading.endsWith('.'), isFalse);
        }
      },
    );

    test('old pages and exactly one label keep the original body', () {
      for (final body in [
        'Old <b>lead</b> text<br><br>End',
        '<b>In short.</b> One<br><br>Plain',
      ]) {
        final blocks = layoutPrimerBody(body, [], sections: true);
        expect(blocks, hasLength(1));
        expect((blocks.single as PrimerTextBlock).html, body);
        expect((blocks.single as PrimerTextBlock).heading, isNull);
      }
    });

    test(
      'repeated labels have separate paragraph identities; figures keep their slots',
      () {
        final blocks = layoutPrimerBody(
          '<b>In short.</b> First<br><br><b>In short.</b> Second<br><br>Continuation',
          [const ConceptExtraFigure(svg: '<svg/>', afterParagraph: 1)],
          sections: true,
        );
        expect(blocks, hasLength(3));
        expect((blocks[0] as PrimerTextBlock).paragraphNumber, 1);
        expect((blocks[0] as PrimerTextBlock).html, 'First');
        expect(blocks[1], isA<PrimerFigureBlock>());
        expect((blocks[2] as PrimerTextBlock).paragraphNumber, 2);
        expect(
          (blocks[2] as PrimerTextBlock).html,
          'Second<br><br>Continuation',
        );
      },
    );

    testWidgets(
      'contents navigates to repeated headings and exposes heading semantics',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildRecallTheme(),
            home: PrimerScreen(
              page: page(
                'sections',
                body:
                    '<b>In short.</b> ${'Long synthetic paragraph. ' * 100}<br><br><b>In short.</b> Final paragraph',
              ),
              conceptNodes: const [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final contents = find.byKey(const Key('recall_primer_contents'));
        final buttons = find.descendant(
          of: contents,
          matching: find.byType(TextButton),
        );
        expect(buttons, findsNWidgets(2));
        await tester.tap(buttons.last);
        await tester.pumpAndSettle();
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scroll.position.pixels, greaterThan(0));
        final headers = find.descendant(
          of: find.byType(PrimerContent),
          matching: find.byWidgetPredicate(
            (widget) => widget is Semantics && widget.properties.header == true,
          ),
        );
        expect(headers, findsNWidgets(2));
        expect(
          tester.getSemantics(headers.last).flagsCollection.isHeader,
          isTrue,
        );
        expect(find.text('Final paragraph').hitTestable(), findsOneWidget);
        semantics.dispose();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('single-label page has no contents or extracted heading', (
      tester,
    ) async {
      const body = '<b>In short.</b> Legacy text';
      await tester.pumpWidget(
        MaterialApp(
          home: PrimerScreen(
            page: page('one', body: body),
            conceptNodes: const [],
          ),
        ),
      );
      expect(find.byKey(const Key('recall_primer_contents')), findsNothing);
      expect(tester.widget<CardFace>(find.byType(CardFace)).html, body);
    });
  });

  group('reading link resolution', () {
    final node = page('node');
    final chat = page('chat-example');
    test('missing page rows and node::none do not produce a link', () {
      expect(
        ConceptAttribution.readingPages('node::missing node::none', [node]),
        isEmpty,
      );
    });
    test('explicit page-only card resolves to its chat page', () {
      expect(
        ConceptAttribution.readingPages('page::chat-example', [node, chat]),
        [chat],
      );
    });
    test(
      'node pages lead explicit pages, deduplicated across both tag forms',
      () {
        expect(
          ConceptAttribution.readingPages(
            'page::chat-example page::node node::node node::node page::chat-example',
            [chat, node],
          ),
          [node, chat],
        );
        expect(ConceptAttribution.nodeTags('page::chat-example node::node'), [
          'node',
        ]);
      },
    );
  });

  Future<({ReviewController controller, FakeRecallApi api})> study(
    WidgetTester tester, {
    String tags = 'page::chat-example',
    List<ConceptPage>? pages,
    String back = '<b>Answer</b><br><i>Hook:</i> Anchor',
    bool maths = false,
    Size size = const Size(360, 800),
    bool revealed = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeRecallApi([
      testCard(tags: tags, back: back, hasLatex: maths),
    ])..conceptPages = pages ?? [page('chat-example')];
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      clock: () => DateTime.utc(2026, 11, 1, 12),
    );
    addTearDown(controller.dispose);
    await controller.load();
    if (revealed) controller.flip();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: Scaffold(
          body: StudyScreen(controller: controller, api: api, nativeIos: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller: controller, api: api);
  }

  for (final width in [360.0, 1200.0]) {
    testWidgets(
      'reading returns to revealed card without rating at width $width',
      (tester) async {
        final (:controller, :api) = await study(
          tester,
          size: Size(width, 800),
          revealed: false,
        );
        final action = find.byKey(const Key('recall_read_explanation'));
        expect(action, findsNothing);
        controller.flip();
        await tester.pumpAndSettle();
        final state = controller.state;
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byType(PrimerScreen), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(controller.state, same(state));
        expect(controller.state.current?.id, 1);
        expect(controller.state.showBack, isTrue);
        expect(controller.state.reviewedThisSession, 0);
        expect(await controller.store.outbox(), isEmpty);
        expect(api.applied, isEmpty);
        expect(api.conceptPageReads, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'several pages offer chooser; cancelling or reading leaves session intact',
    (tester) async {
      final (:controller, :api) = await study(
        tester,
        tags: 'page::chat-example node::node',
        pages: [page('chat-example'), page('node')],
      );
      final state = controller.state;
      final action = find.byKey(const Key('recall_read_explanation'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect((rows.first.title as Text).data, page('node').title);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(controller.state, same(state));
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PrimerScreen>(find.byType(PrimerScreen)).page.nodeId,
        'chat-example',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(controller.state, same(state));
      expect(await controller.store.outbox(), isEmpty);
      expect(api.applied, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('card with node tag but no page row has no action', (
    tester,
  ) async {
    await study(tester, tags: 'node::missing');
    expect(find.byKey(const Key('recall_read_explanation')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  group('answer and anchor', () {
    test(
      'legacy backs, unbold first lines, lists and nested breaks stay whole',
      () {
        for (final back in [
          '<b>Answer</b>',
          'Answer<br>Anchor',
          '<b>Part</b> rest<br>Anchor',
          '<ul><li><b>Answer</b><br>Anchor</li></ul>',
          '<b>Answer</b><br><ol><li>Anchor</li></ol>',
          '<b>Answer<br>Still answer</b>',
          r'\(x\) and \(y\)<br>Anchor',
        ]) {
          expect(splitCardBack(back), isNull, reason: back);
        }
      },
    );
    test('bold or one inline/display expression preserves both HTML parts', () {
      for (final answer in [
        '<b>Answer</b>',
        r'\(x < y\)',
        r'\[x^2\]',
        r'$$x^2$$',
        '<b>{{c1::Answer}}</b>',
      ]) {
        final parts = splitCardBack('$answer<br><i>Hook:</i> Anchor<br>More');
        expect(parts, (answer: answer, anchor: '<i>Hook:</i> Anchor<br>More'));
      }
    });
    testWidgets(
      'display maths and cloze anchor use existing rendering pipeline',
      (tester) async {
        await study(
          tester,
          tags: '',
          maths: true,
          back: r'\[x^2\]<br><i>Hook:</i> {{c1::Anchor}}',
        );
        expect(find.byType(Math), findsWidgets);
        final faces = tester
            .widgetList<CardFace>(find.byType(CardFace))
            .toList();
        expect(
          faces.map((face) => face.html),
          containsAll([r'\[x^2\]', '<i>Hook:</i> {{c1::Anchor}}']),
        );
        expect(
          faces
              .where((face) => face.html.contains('Anchor'))
              .single
              .revealCloze,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}

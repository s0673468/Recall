import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/concept_retention_panel.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

void main() {
  group('RecallApi.fetchConceptPages', () {
    test('selects the primer fields from concept_pages', () async {
      late Uri requestedUri;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            jsonEncode([
              {
                'node_id': 'm00-vector-geometry',
                'title': 'Vector geometry',
                'body_html': r'<b>Projection</b>: \(x\)',
                'figure_svg':
                    '<svg xmlns="http://www.w3.org/2000/svg" '
                    'viewBox="0 0 10 5"><rect width="10" height="5"/></svg>',
                'updated_at': '2026-07-29T12:00:00.000Z',
              },
            ]),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);

      final pages = await RecallApi(client).fetchConceptPages();

      expect(requestedUri.path, '/rest/v1/concept_pages');
      expect(
        requestedUri.queryParameters['select'],
        'node_id,title,body_html,figure_svg,updated_at',
      );
      expect(pages, hasLength(1));
      expect(pages.single.nodeId, 'm00-vector-geometry');
      expect(pages.single.title, 'Vector geometry');
      expect(pages.single.bodyHtml, r'<b>Projection</b>: \(x\)');
      expect(pages.single.figureSvg, contains('<svg'));
      expect(
        pages.single.updatedAt,
        DateTime.parse('2026-07-29T12:00:00.000Z'),
      );
    });

    test('returns empty when PostgREST reports a missing table', () async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'code': '42P01',
              'message': 'relation "public.concept_pages" does not exist',
              'details': null,
              'hint': null,
            }),
            404,
            request: request,
            headers: {'content-type': 'application/json'},
          ),
        ),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);

      await expectLater(
        RecallApi(client).fetchConceptPages(),
        completion(isEmpty),
      );
    });
  });

  group('concept primer navigation', () {
    const node = ConceptNodeInfo(
      nodeId: 'm00-vector-geometry',
      title: 'Vector geometry',
      module: 'M00',
    );
    final page = ConceptPage(
      nodeId: node.nodeId,
      title: 'Vector geometry primer',
      bodyHtml: r'Use <b>projection</b> with \(x\).',
      figureSvg:
          '<svg xmlns="http://www.w3.org/2000/svg" '
          'viewBox="0 0 20 10"><rect width="20" height="10"/></svg>',
      updatedAt: DateTime.utc(2026, 7, 29),
    );
    const retention = NodeRetention(
      nodeId: 'm00-vector-geometry',
      title: 'Vector geometry',
      module: 'M00',
      reviews: 8,
      againCount: 3,
    );

    testWidgets('primer row opens a CardFace-rendered primer', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: ConceptRetentionPanel(
              ranked: const [retention],
              notEnoughData: 0,
              coveredNodeCount: 1,
              totalConcepts: 1,
              conceptPages: [page],
              conceptNodes: const [node],
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      await tester.tap(find.text('Vector geometry'));
      await tester.pumpAndSettle();

      expect(find.byType(PrimerScreen), findsOneWidget);
      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.text('M00'), findsOneWidget);
      expect(find.byType(Math), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      InlineSpan? projection;
      selectable.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.text == 'projection') projection = span;
        return true;
      });
      expect((projection as TextSpan?)?.style?.fontWeight, FontWeight.w700);
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed primer SVG is omitted without crashing', (
      tester,
    ) async {
      final malformed = ConceptPage(
        nodeId: node.nodeId,
        title: 'Malformed figure primer',
        bodyHtml: 'The body still renders.',
        figureSvg: '<svg><not-closed>',
        updatedAt: DateTime.utc(2026, 7, 29),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: PrimerScreen(page: malformed, conceptNodes: const [node]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('The body still renders.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('zero primers preserves the legacy panel widget output', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: const Scaffold(
            body: ConceptRetentionPanel(
              ranked: [retention],
              notEnoughData: 0,
              coveredNodeCount: 1,
              totalConcepts: 1,
            ),
          ),
        ),
      );

      expect(find.byType(InkWell), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.text('Browse concept primers'), findsNothing);
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('library groups primers by ascending module id', (
      tester,
    ) async {
      final pages = [
        ConceptPage(
          nodeId: 'm02-loss',
          title: 'Loss functions',
          bodyHtml: 'Loss',
          updatedAt: DateTime.utc(2026, 7, 29),
        ),
        page,
      ];
      const nodes = [
        node,
        ConceptNodeInfo(
          nodeId: 'm02-loss',
          title: 'Loss functions',
          module: 'M02',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: PrimerLibraryScreen(pages: pages, conceptNodes: nodes),
        ),
      );

      final m00 = tester.getTopLeft(find.text('M00')).dy;
      final m02 = tester.getTopLeft(find.text('M02')).dy;
      expect(m00, lessThan(m02));
      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.text('Loss functions'), findsOneWidget);
    });
  });
}

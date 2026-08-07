import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/domain/concept_attribution.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

ReviewLogEntry _review(String? guid, DateTime at, int rating) =>
    ReviewLogEntry(guid: guid, at: at, rating: rating);

void main() {
  group('nodeTags', () {
    test(
      'parses node:: tokens, dedupes, drops node::none and non-node tags',
      () {
        expect(
          ConceptAttribution.nodeTags(
            'leech node::m00-a marked node::m01-b node::m00-a',
          ),
          ['m00-a', 'm01-b'],
        );
        expect(ConceptAttribution.nodeTags('node::none node::m02-c'), [
          'm02-c',
        ]);
        expect(ConceptAttribution.nodeTags('node:: node::none'), isEmpty);
        expect(ConceptAttribution.nodeTags(null), isEmpty);
        expect(ConceptAttribution.nodeTags(''), isEmpty);
      },
    );
  });

  group('todayConceptPages', () {
    final today = DateTime(2026, 7, 29, 12);
    final pageA = ConceptPage(
      nodeId: 'm00-a',
      title: 'A primer',
      bodyHtml: 'A',
      updatedAt: DateTime.utc(2026, 7, 29),
    );
    final pageB = ConceptPage(
      nodeId: 'm01-b',
      title: 'B primer',
      bodyHtml: 'B',
      updatedAt: DateTime.utc(2026, 7, 29),
    );

    test('returns primers tagged to cards reviewed on the local day', () {
      final pages = ConceptAttribution.todayConceptPages(
        reviewLog: [
          _review('g1', DateTime(2026, 7, 29, 0, 1), 3),
          _review('g2', DateTime(2026, 7, 28, 23, 59), 3),
        ],
        noteTags: {'g1': 'node::m00-a node::none', 'g2': 'node::m01-b'},
        conceptPages: [pageB, pageA],
        today: today,
      );

      expect(pages.map((page) => page.nodeId), ['m00-a']);
    });

    test('returns no primers for untagged or primer-less reviews', () {
      final pages = ConceptAttribution.todayConceptPages(
        reviewLog: [
          _review('untagged', today, 3),
          _review('no-page', today, 3),
        ],
        noteTags: {'no-page': 'node::m99-missing'},
        conceptPages: [pageA, pageB],
        today: today,
      );

      expect(pages, isEmpty);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

// Metadata only: no card/article content, storage, accounts or transport.
final _now = DateTime(2026, 10, 24, 12);

class _Api implements RecallApi {
  int reviewReads = 0;
  int tagReads = 0;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream.empty();

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    reviewReads++;
    return [
      ReviewLogEntry(cardId: 7, guid: 'synthetic-note', at: _now, rating: 3),
    ];
  }

  @override
  Future<Map<String, String>> fetchNoteTags() async {
    tagReads++;
    return {'synthetic-note': 'node::synthetic-primer'};
  }

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => const [
    ConceptNodeInfo(
      nodeId: 'synthetic-primer',
      title: 'Synthetic primer',
      module: 'Synthetic module',
    ),
  ];

  @override
  Future<List<ConceptPage>> fetchConceptPages() async => [
    ConceptPage(
      nodeId: 'synthetic-primer',
      title: 'Synthetic primer',
      bodyHtml: '',
      updatedAt: _now,
    ),
  ];

  @override
  Future<List<DeckRow>> fetchDecks() async => const [];

  @override
  Future<Set<int>> fetchHiddenCardIds() async => const {};

  @override
  Future<List<DateTime>> fetchDueDates({
    Set<int>? includedDeckIds,
    Set<int> excludeCardIds = const {},
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Synthetic offline metadata source');
}

class _Store extends LocalReviewStore {
  @override
  Future<List<Map<String, dynamic>>> likedFlags({String? ownerScope}) async => [
    // The production likes cache stores withdrawal identities without GUIDs.
    {'card_id': 7, 'client_id': 'synthetic-like', 'reason': 'like'},
    {'card_id': 99, 'client_id': 'synthetic-unmapped-like', 'reason': 'like'},
  ];

  @override
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) async =>
      [];
}

void main() {
  testWidgets(
    'Stats library maps cached likes using its loaded review identities',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      final controller = ReviewController(
        api: api,
        store: _Store(),
        engine: FsrsEngine(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: StatsScreen(
              api: api,
              controller: controller,
              clock: () => _now,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Concepts to reinforce'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browse concept primers'));
      await tester.pumpAndSettle();

      final row = find.byKey(
        const ValueKey('recall_primer_row_synthetic-primer'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(Icons.thumb_up_outlined),
        ),
        findsOneWidget,
      );
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('Has liked cards')), findsOneWidget);
      semantics.dispose();
      expect(api.reviewReads, 1);
      expect(api.tagReads, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

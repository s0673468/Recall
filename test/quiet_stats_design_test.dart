import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/due_forecast_chart.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

class _StatsController extends ChangeNotifier implements ReviewController {
  @override
  final state = const ReviewState(loading: false, reviewedThisSession: 11);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StatsApi implements RecallApi {
  final dueCompleter = Completer<List<DateTime>>();
  bool failConcepts = false;
  int reviewLoads = 0;
  Set<int>? includedDeckIds;
  final now = DateTime.now();

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    reviewLoads++;
    return [
      for (var i = 0; i < 4; i++)
        ReviewLogEntry(
          guid: 'g1',
          at: now,
          rating: i == 0 ? 1 : 3,
          dueAfter: now.add(Duration(days: i < 2 ? 3 : 30)),
        ),
      ReviewLogEntry(at: now.subtract(const Duration(days: 45)), rating: 1),
    ];
  }

  @override
  Future<List<DeckRow>> fetchDecks() async => const [
    DeckRow(deckId: 1, name: 'ML'),
    DeckRow(deckId: 2, name: 'Opt-in::Portuguese'),
  ];

  @override
  Future<List<DateTime>> fetchDueDates({Set<int>? includedDeckIds}) {
    this.includedDeckIds = includedDeckIds;
    return dueCompleter.future;
  }

  @override
  Future<Map<String, String>> fetchNoteTags() async => {'g1': 'node::models'};

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async {
    if (failConcepts) throw StateError('Concepts unavailable');
    return const [
      ConceptNodeInfo(
        nodeId: 'models',
        title: 'Models and generalization across unfamiliar examples',
        module: 'Machine learning',
      ),
    ];
  }

  @override
  Future<List<ConceptPage>> fetchConceptPages() async => [
    ConceptPage(
      nodeId: 'models',
      title: 'Models and generalization across unfamiliar examples',
      bodyHtml: 'A model should work on unseen examples.',
      updatedAt: now,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pumpStats(
    WidgetTester tester,
    _StatsApi api, {
    double width = 390,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _StatsController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: StatsScreen(api: api, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    final heading = find.text(title);
    await tester.ensureVisible(heading);
    await tester.tap(heading);
    await tester.pumpAndSettle();
  }

  testWidgets('retention window updates real totals without refetching', (
    tester,
  ) async {
    final api = _StatsApi()..dueCompleter.complete([]);
    await pumpStats(tester, api);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('3 of 4 scheduled reviews remembered.'), findsOneWidget);
    expect(find.byKey(const Key('recall_stats_history_strip')), findsOneWidget);
    expect(find.byKey(const Key('recall_stats_session_strip')), findsNothing);
    expect(find.byType(ReviewHeatmap), findsNothing);
    await tester.tap(find.byKey(const Key('recall_retention_window')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90 days').last);
    await tester.pumpAndSettle();
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('3 of 5 scheduled reviews remembered.'), findsOneWidget);
    expect(api.reviewLoads, 1);
    expect(api.includedDeckIds, {1});
    await expand(tester, 'Current session');
    expect(find.text('11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closed sections handle independent failures before being opened',
    (tester) async {
      final api = _StatsApi()..failConcepts = true;
      await pumpStats(tester, api);
      api.dueCompleter.completeError(StateError('Forecast unavailable'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('Could not load forecast.'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('stats_section_error_forecast'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      await expand(tester, 'Work ahead');
      expect(find.text('Could not load forecast.'), findsOneWidget);
      await expand(tester, 'Concepts to reinforce');
      expect(find.text('Could not load concepts.'), findsOneWidget);
      await expand(tester, 'Activity');
      expect(find.byType(ReviewHeatmap), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all Stats detail remains usable at 320px with double text size',
    (tester) async {
      final api = _StatsApi();
      api.dueCompleter.complete([
        for (var i = 0; i < 40; i++) api.now.add(Duration(days: i % 14)),
      ]);
      await pumpStats(tester, api, width: 320, textScale: 2);
      for (final title in [
        'Young and mature cards',
        'Activity',
        'Work ahead',
        'Concepts to reinforce',
        'Current session',
      ]) {
        await expand(tester, title);
        expect(tester.takeException(), isNull, reason: title);
      }
      expect(find.text('Young'), findsOneWidget);
      expect(find.text('Mature'), findsOneWidget);
      expect(find.text('25% again · 4 reviews'), findsOneWidget);
      final chartScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(DueForecastChart),
          matching: find.byType(Scrollable),
        ),
      );
      expect(chartScroll.position.maxScrollExtent, greaterThan(300));
      expect(tester.takeException(), isNull);
    },
  );
}

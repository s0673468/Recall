import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/due_forecast_chart.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Decks screen', () {
    testWidgets('a count failure is visible and never looks like zero due', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()])..failDeckCounts = true;
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: DecksScreen(
              controller: controller,
              api: api,
              onStudyDeck: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load deck counts.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('0 due'), findsNothing);
      expect(
        find.byKey(const Key('recall_deck_row_Automatic review')),
        findsOneWidget,
      );
    });

    testWidgets(
      'renders one review hero and separates core from opt-in decks',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FakeRecallApi(
          [testCard()],
          decks: const [
            DeckRow(deckId: 1, name: 'ML'),
            DeckRow(deckId: 2, name: 'Portuguese'),
          ],
        )..deckCounts = const {1: (due: 4, neu: 1), 2: (due: 3, neu: 2)};
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: LocalReviewStore(),
        );
        addTearDown(controller.dispose);
        await controller.load();

        await tester.pumpWidget(
          MaterialApp(
            theme: buildRecallTheme(),
            home: Scaffold(
              body: DecksScreen(
                controller: controller,
                api: api,
                onStudyDeck: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('recall_deck_row_Automatic review')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recall_deck_hero')), findsOneWidget);
        expect(find.text('Included in automatic review'), findsOneWidget);
        expect(find.text('Optional curricula'), findsOneWidget);
        expect(
          find.byKey(const Key('recall_deck_row_Portuguese')),
          findsNothing,
        );
        await tester.tap(find.text('Optional curricula'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('recall_deck_row_Portuguese')),
          findsOneWidget,
        );
        expect(find.textContaining('3 due'), findsOneWidget);
        expect(find.textContaining('2 new'), findsOneWidget);
        expect(find.text('Open manually'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('reload keeps the state update synchronous', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi(
        [testCard()],
        decks: const [DeckRow(deckId: 1, name: 'Portuguese')],
      )..deckCounts = const {1: (due: 3, neu: 2)};
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecksScreen(
              controller: controller,
              api: api,
              onStudyDeck: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.state<DecksScreenState>(find.byType(DecksScreen)).reload();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Optional curricula'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 due'), findsOneWidget);
    });
  });

  group('Stats screen', () {
    testWidgets('work-ahead forecast excludes manual-only decks', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final api =
          FakeRecallApi(
              [testCard()],
              decks: const [
                DeckRow(deckId: 1, name: 'ML'),
                DeckRow(deckId: 2, name: 'Opt-in::Portuguese'),
              ],
            )
            ..scheduledDueDates = [
              (deckId: 1, due: now.add(const Duration(days: 1))),
              (deckId: 2, due: now.add(const Duration(days: 1))),
            ];
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatsScreen(api: api, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openStatsDetails(tester, 'forecast');
      await tester.dragUntilVisible(
        find.byType(DueForecastChart),
        find.byType(Scrollable).first,
        const Offset(0, -300),
      );
      final chart = tester.widget<DueForecastChart>(
        find.byType(DueForecastChart),
      );
      expect(api.lastDueDateDeckIds, {1});
      expect(chart.days.fold<int>(0, (sum, day) => sum + day.count), 1);
    });

    testWidgets('a failed forecast query does not blank the heatmap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()]);
      api.reviewLog = [ReviewLogEntry(at: DateTime.now(), rating: 3)];
      api.failDueDates = true; // only the forecast query fails
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatsScreen(api: api, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Supporting query failures stay isolated, including before disclosure.
      expect(find.byKey(const Key('recall_retention_hero')), findsOneWidget);
      expect(
        find.byKey(const Key('recall_stats_history_strip')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _openStatsDetails(tester, 'session');
      expect(
        find.byKey(const Key('recall_stats_session_strip')),
        findsOneWidget,
      );
      await _openStatsDetails(tester, 'activity');
      expect(find.byType(ReviewHeatmap), findsOneWidget);
      await _openStatsDetails(tester, 'forecast');
      expect(find.text('Could not load forecast.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _openStatsDetails(WidgetTester tester, String section) async {
  final tile = find.byKey(PageStorageKey('recall_stats_disclosure_$section'));
  await tester.ensureVisible(tile);
  await tester.tap(
    find.descendant(of: tile, matching: find.byType(ListTile)).first,
  );
  await tester.pumpAndSettle();
}

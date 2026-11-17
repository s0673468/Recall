import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/app/recall_app.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';

import 'recall_acceptance_fixture.dart';

// One procedure shared by the VM gate and the Android main-path run.
// Error-injection scenarios stay in the unit suite, outside the normal path recipe.
Future<void> exerciseRecallMainPaths(WidgetTester tester) async {
  const phoneSize = Size(411, 914);
  final fixedNow = DateTime.utc(2026, 8, 23, 12);
  Finder navigationLabel(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  tester.view.physicalSize = phoneSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final dependencies = await createSanitizedAcceptanceDependencies(
    scenario: AcceptanceScenario.rich,
    now: fixedNow,
  );
  final api = dependencies.api as SanitizedRecallApi;

  await tester.pumpWidget(RecallApp(dependencies: dependencies));
  debugDefaultTargetPlatformOverride = null;
  await tester.pumpAndSettle();

  expect(find.byKey(const ValueKey('recall_shell')), findsOneWidget);
  expect(find.byKey(const Key('recall_study_card')), findsOneWidget);
  expect(find.byKey(const ValueKey('study_catch_up_offer')), findsNothing);
  expect(find.text('Large due backlog'), findsNothing);

  await tester.tap(find.text('Show answer'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('study_rating_bar')), findsOneWidget);

  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Flag card'));
  await tester.pumpAndSettle();
  expect(find.text('Flag this card'), findsOneWidget);
  await tester.tap(find.text('Confusing'));
  await tester.pumpAndSettle();
  expect(find.text('Flagged for the weekly review'), findsOneWidget);
  expect(api.appliedFlags.single['reason'], 'confusing');
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Good'));
  await tester.pumpAndSettle();
  expect(dependencies.reviewController.state.reviewedThisSession, 1);
  expect(
    tester
        .widget<IconButton>(find.byKey(const Key('recall_study_undo')))
        .onPressed,
    isNull,
  );
  expect(find.text('Synced reviews cannot be undone'), findsNothing);
  expect(
    find.text('${dependencies.reviewController.state.reviewedToday} done'),
    findsOneWidget,
  );
  await dependencies.reviewController.undo();
  expect(dependencies.reviewController.state.reviewedThisSession, 1);
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();

  await tester.tap(navigationLabel('Decks'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('recall_deck_hero')), findsOneWidget);
  await tester.enterText(
    find.byKey(const Key('recall_deck_search')),
    'Portuguese',
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('recall_deck_row_Portuguese')),
    500,
    scrollable: find
        .descendant(
          of: find.byType(DecksScreen),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  expect(
    find.byKey(const ValueKey('recall_deck_row_Portuguese')),
    findsOneWidget,
  );

  await tester.tap(navigationLabel('Stats'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('recall_retention_hero')), findsOneWidget);
  expect(find.byKey(const Key('recall_stats_history_strip')), findsOneWidget);
  final statsScroll = find
      .descendant(
        of: find.byType(StatsScreen),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.ensureVisible(
    find.byKey(const PageStorageKey('recall_stats_disclosure_forecast')),
  );
  await tester.tap(
    find
        .descendant(
          of: find.byKey(
            const PageStorageKey('recall_stats_disclosure_forecast'),
          ),
          matching: find.byType(ListTile),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('stats_section_content_forecast')),
    500,
    scrollable: statsScroll,
  );
  expect(
    find.byKey(const ValueKey('stats_section_content_forecast')),
    findsOneWidget,
  );
  await tester.ensureVisible(
    find.byKey(const PageStorageKey('recall_stats_disclosure_concepts')),
  );
  await tester.tap(
    find
        .descendant(
          of: find.byKey(
            const PageStorageKey('recall_stats_disclosure_concepts'),
          ),
          matching: find.byType(ListTile),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('recall_concepts_panel')),
    500,
    scrollable: statsScroll,
  );
  expect(find.byKey(const Key('recall_concepts_panel')), findsOneWidget);

  await tester.tap(navigationLabel('Read'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('read_content')), findsOneWidget);
  await tester.scrollUntilVisible(
    find.byKey(const Key('recall_primer_search')),
    400,
    scrollable: find
        .descendant(
          of: find.byType(ReadScreen),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  expect(find.byKey(const Key('recall_primer_search')), findsOneWidget);
  await tester.enterText(
    find.byKey(const Key('recall_primer_search')),
    'concept 72',
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('recall_primer_row_concept-72')),
    findsOneWidget,
  );

  await tester.tap(navigationLabel('Study'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
  expect(find.text('Scheduling'), findsOneWidget);
  expect(find.text('Daily reminder'), findsNothing);
  expect(find.byTooltip('Decrease New cards / day'), findsOneWidget);
  expect(find.byTooltip('Increase New cards / day'), findsOneWidget);
  final settingsScroll = find
      .descendant(
        of: find.byType(SettingsScreen),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    find.text('Per-deck new-card limits'),
    500,
    scrollable: settingsScroll,
  );
  expect(find.text('Per-deck new-card limits'), findsOneWidget);
  await tester.scrollUntilVisible(
    find.text('Account'),
    500,
    scrollable: settingsScroll,
  );
  expect(find.text('Account'), findsOneWidget);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  dependencies.dispose();
  await tester.pump();
}

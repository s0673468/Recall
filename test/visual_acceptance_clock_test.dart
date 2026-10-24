import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/desktop_reading_pane.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/due_forecast_chart.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  testWidgets('Stats uses its clock across the Saturday to Sunday boundary', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final saturday = DateTime(2026, 10, 24, 12);
    final sunday = DateTime(2026, 10, 25, 12);
    var now = saturday;
    final api = FakeRecallApi([])
      ..reviewLog = [
        for (var day = 18; day <= 25; day++)
          ReviewLogEntry(at: DateTime(2026, 10, day, 10), rating: 3),
      ]
      ..dueDates = [sunday];
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
    );
    addTearDown(controller.dispose);
    final screenKey = GlobalKey<StatsScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: Scaffold(
          body: StatsScreen(
            key: screenKey,
            api: api,
            controller: controller,
            clock: () => now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final title in ['Activity', 'Work ahead']) {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    List<HeatmapDay> heatmap() => tester
        .widget<ReviewHeatmap>(find.byType(ReviewHeatmap, skipOffstage: false))
        .days;
    List<ForecastDay> forecast() => tester
        .widget<DueForecastChart>(
          find.byType(DueForecastChart, skipOffstage: false),
        )
        .days;

    expect(heatmap().last.date, DateTime(2026, 10, 24));
    expect(heatmap().skip(175).map((day) => day.count), [1, 1, 1, 1, 1, 1, 1]);
    expect(forecast().first.date, DateTime(2026, 10, 24));
    expect(forecast().take(2).map((day) => day.count), [0, 1]);

    // Reuse both the screen state and the cached data. Only the clock advances.
    now = sunday;
    await screenKey.currentState!.reload();
    await tester.pumpAndSettle();
    expect(heatmap().last.date, DateTime(2026, 10, 31));
    expect(heatmap().skip(175).map((day) => day.count), [1, 0, 0, 0, 0, 0, 0]);
    expect(forecast().first.date, DateTime(2026, 10, 25));
    expect(forecast().take(2).map((day) => day.count), [1, 0]);
    expect(api.reviewLogReads, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final inPane in [false, true]) {
    testWidgets('Reading clock controls recent lists (pane: $inPane)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime(2026, 10, 24, 12);
      final api = FakeRecallApi([])
        ..conceptPages = [
          ConceptPage(
            nodeId: 'vectors',
            title: 'Synthetic vectors',
            bodyHtml: '<p>A synthetic primer.</p>',
            updatedAt: now,
          ),
          ConceptPage(
            nodeId: 'chat-synthetic',
            title: 'Synthetic weekly notes',
            bodyHtml: '<p>A synthetic summary.</p>',
            updatedAt: now,
          ),
        ]
        ..reviewLog = [ReviewLogEntry(guid: 'vector', at: now, rating: 3)]
        ..noteTags = {'vector': 'node::vectors'};
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: inPane
                ? DesktopReadingPane(
                    api: api,
                    controller: controller,
                    store: LocalReviewStore(),
                    clock: () => now,
                  )
                : ReadScreen(api: api, clock: () => now),
          ),
        ),
      );
      await tester.pumpAndSettle();
      const emptyMessage =
          'Nothing reviewed in the last 3 days. Your full library is ready below.';
      expect(find.byKey(const Key('recall_read_chats')), findsOneWidget);
      expect(find.text(emptyMessage), findsNothing);

      // Age the same fixtures beyond both the 3-day and 14-day windows.
      now = DateTime(2026, 11, 8, 12);
      final read = tester.state<ReadScreenState>(find.byType(ReadScreen));
      await read.reload();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recall_read_chats')), findsNothing);
      expect(find.text(emptyMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

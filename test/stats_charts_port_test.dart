import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/stats_service.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/due_forecast_chart.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

final _today = DateTime(2026, 10, 25);
final _log = [
  for (var day = 0; day < 180; day++)
    for (var n = 0; n < (day * 7) % 19; n++)
      ReviewLogEntry(
        at: _today.subtract(Duration(days: day)),
        rating: n % 5 == 0 ? 1 : 3,
        dueAfter: _today.add(const Duration(days: 7)),
      ),
];
final _due = [
  for (var i = 0; i < 640; i++) _today.subtract(const Duration(days: 2)),
  for (var day = 1; day <= 14; day++)
    for (var n = 0; n < (day * 7) % 23; n++) _today.add(Duration(days: day)),
];

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  final state = const ReviewState(loading: false);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements RecallApi {
  final pendingLog = Completer<List<ReviewLogEntry>>();
  final pendingDue = Completer<List<DateTime>>();
  void complete({bool empty = false}) {
    pendingLog.complete(empty ? [] : _log);
    pendingDue.complete(empty ? [] : _due);
  }

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) =>
      pendingLog.future;
  @override
  Future<List<DateTime>> fetchDueDates({
    Set<int>? includedDeckIds,
    Set<int> excludeCardIds = const {},
  }) => pendingDue.future;
  @override
  Future<List<DeckRow>> fetchDecks() async => const [
    DeckRow(deckId: 1, name: 'Synthetic fixture deck'),
  ];
  @override
  Future<Map<String, String>> fetchNoteTags() async => {};
  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => [];
  @override
  Future<List<ConceptPage>> fetchConceptPages() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      theme: buildRecallTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: const Key('stats_capture'),
          child: ColoredBox(
            color: UiColors.canvas,
            child: Column(
              children: [
                const Text(
                  'Synthetic Stats preview',
                  style: TextStyle(fontSize: 12),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: child,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _expand(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title));
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  Widget chartPage(Widget chart) => SingleChildScrollView(
    child: Padding(padding: const EdgeInsets.all(16), child: chart),
  );

  for (final width in [360.0, 390.0]) {
    testWidgets('forecast separates Now and fits two weeks at $width', (
      tester,
    ) async {
      final days = StatsService.buildForecast(_due, today: _today, days: 15);
      await _pump(
        tester,
        chartPage(DueForecastChart(days: days)),
        width: width,
      );
      expect(find.text('due now'), findsOneWidget);
      expect(find.text('640'), findsOneWidget);
      final maxDaily = days
          .skip(1)
          .map((d) => d.count)
          .reduce((a, b) => a > b ? a : b);
      expect(
        find.text(
          'Now includes overdue cards. Daily scale: 0-$maxDaily cards.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('640')).style?.color,
        UiColors.textPrimary,
      );
      final rows = <double>{};
      for (var i = 1; i <= 14; i++) {
        final label = find.byKey(ValueKey('forecast_date_$i'));
        final cell = find.byKey(ValueKey('forecast_day_$i'));
        expect(label, findsOneWidget);
        final rect = tester.getRect(cell);
        expect(rect.width, greaterThanOrEqualTo(44));
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(width - 16 + 0.01));
        rows.add(rect.top);
      }
      expect(rows.length, 2);
      expect(
        tester.getTopLeft(find.byKey(const Key('forecast_day_1'))).dy,
        tester.getTopLeft(find.byKey(const Key('forecast_day_7'))).dy,
      );
      final tallest = days.skip(1).firstWhere((d) => d.count == maxDaily);
      expect(
        tester
            .getSize(find.byKey(ValueKey('forecast_bar_${tallest.index}')))
            .height,
        96,
      );
      expect(
        find.descendant(
          of: find.byType(DueForecastChart),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      final readout = find.byKey(const Key('forecast_readout'));
      final height = tester.getSize(readout).height;
      final gridTop = tester.getTopLeft(
        find.byKey(const Key('forecast_daily_grid')),
      );
      await tester.tap(find.byKey(const Key('forecast_day_1')));
      await tester.pump();
      expect(find.text('2026-10-26 · 7 cards due'), findsOneWidget);
      expect(tester.getSize(readout).height, height);
      expect(
        tester.getTopLeft(find.byKey(const Key('forecast_daily_grid'))),
        gridTop,
      );
      expect(
        (tester
                    .widget<Container>(find.byKey(const Key('forecast_bar_1')))
                    .decoration!
                as BoxDecoration)
            .color,
        UiColors.primary,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('Now backlog cannot move the daily grid at text scale $scale', (
      tester,
    ) async {
      final count = ValueNotifier(0);
      addTearDown(count.dispose);
      await _pump(
        tester,
        chartPage(
          ValueListenableBuilder<int>(
            valueListenable: count,
            builder: (context, value, _) => DueForecastChart(
              days: [
                for (var i = 0; i <= 14; i++)
                  ForecastDay(
                    date: _today.add(Duration(days: i)),
                    index: i,
                    count: i == 0 ? value : i,
                  ),
              ],
            ),
          ),
        ),
        width: 1280,
        scale: scale,
      );
      final grid = find.byKey(const Key('forecast_daily_grid'));
      final bounds = tester.getRect(grid);
      final firstBar = tester.getRect(find.byKey(const Key('forecast_bar_1')));
      count.value = 1000000;
      await tester.pump();
      expect(find.text('1000000'), findsOneWidget);
      expect(tester.getRect(grid), bounds);
      expect(tester.getRect(find.byKey(const Key('forecast_bar_1'))), firstBar);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'heatmap fills its desktop column and supports pointer and keyboard',
    (tester) async {
      final days = StatsService.buildHeatmap(_log, today: _today);
      await _pump(tester, chartPage(ReviewHeatmap(days: days)), width: 1280);
      final grid = find.byKey(const Key('heatmap_grid'));
      expect(
        tester.getSize(grid).width,
        greaterThanOrEqualTo(
          tester.getSize(find.byType(ReviewHeatmap)).width * 0.9,
        ),
      );
      final cell = tester.getSize(find.byKey(const Key('heatmap_day_0')));
      expect(cell.width, cell.height);
      for (final hint in ['M', 'W', 'F', 'Less', 'More', 'May']) {
        expect(find.text(hint), findsOneWidget);
      }
      expect(
        tester.getTopRight(find.text('More')).dx,
        tester.getTopRight(find.byType(ReviewHeatmap)).dx,
      );
      final readout = find.byKey(const Key('heatmap_readout'));
      final height = tester.getSize(readout).height;
      String value(int index) {
        final day = days[index];
        final date = day.date.toIso8601String().split('T').first;
        return '$date · ${day.count} reviews';
      }

      await tester.tap(find.byKey(const Key('heatmap_day_10')));
      await tester.pump();
      expect(find.text(value(10)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text(value(17)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(find.text(value(16)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.text(value(10)), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('heatmap_day_20'))),
      );
      await tester.pump();
      expect(find.text(value(20)), findsOneWidget);
      expect(tester.getSize(readout).height, height);
      await mouse.removePointer();
      final focus = tester
          .widget<Focus>(find.byKey(const Key('heatmap_focus')))
          .focusNode!;
      expect(focus.hasFocus, isTrue);
      expect(
        find.descendant(
          of: find.byType(ReviewHeatmap),
          matching: find.byType(Focus),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('charts keep concise complete screen-reader summaries', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      chartPage(
        Column(
          children: [
            ReviewHeatmap(days: StatsService.buildHeatmap(_log, today: _today)),
            DueForecastChart(
              days: StatsService.buildForecast(_due, today: _today, days: 15),
            ),
          ],
        ),
      ),
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Review activity, week of ')),
      findsNWidgets(26),
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Due forecast\. Today: 640 cards due;')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  for (final width in [320.0, 360.0, 390.0, 1280.0]) {
    testWidgets('charts and readouts support 200% text at $width', (
      tester,
    ) async {
      await _pump(
        tester,
        chartPage(
          Column(
            children: [
              ReviewHeatmap(
                days: StatsService.buildHeatmap(_log, today: _today),
              ),
              DueForecastChart(
                days: StatsService.buildForecast(_due, today: _today, days: 15),
              ),
            ],
          ),
        ),
        width: width,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomLeft(find.text('M')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('W')).dy + 0.01),
      );
      expect(
        tester.getBottomLeft(find.text('W')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('F')).dy + 0.01),
      );
      final readout = find.byKey(const Key('forecast_readout'));
      final height = tester.getSize(readout).height;
      await tester.ensureVisible(find.byKey(const Key('forecast_day_14')));
      await tester.tap(find.byKey(const Key('forecast_day_14')));
      await tester.pump();
      expect(find.text('2026-11-08 · 6 cards due'), findsOneWidget);
      expect(tester.getSize(readout).height, height);
      for (var i = 1; i <= 14; i++) {
        final rect = tester.getRect(find.byKey(ValueKey('forecast_day_$i')));
        expect(rect.width, greaterThanOrEqualTo(44));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final empty in [false, true]) {
        testWidgets(
          'skeleton to ${empty ? 'empty' : 'data'} keeps layout at $width x$scale',
          (tester) async {
            final controller = _Controller();
            addTearDown(controller.dispose);
            final api = _Api();
            await _pump(
              tester,
              StatsScreen(
                api: api,
                controller: controller,
                clock: () => _today,
              ),
              width: width,
              scale: scale,
              settle: false,
            );
            expect(find.byType(CircularProgressIndicator), findsNothing);
            final keys = [
              for (final id in ['activity', 'forecast', 'concepts', 'session'])
                PageStorageKey('recall_stats_disclosure_$id'),
            ];
            final positions = [
              for (final key in keys) tester.getTopLeft(find.byKey(key)),
            ];
            api.complete(empty: empty);
            await tester.pumpAndSettle();
            for (var i = 0; i < keys.length; i++) {
              expect(
                tester.getTopLeft(find.byKey(keys[i])),
                positions[i],
                reason: '${keys[i]}',
              );
            }
            for (final paragraph in tester.renderObjectList<RenderParagraph>(
              find.byType(RichText),
            )) {
              if (RegExp(r'\d').hasMatch(paragraph.text.toPlainText())) {
                expect(
                  paragraph.text.style?.fontFeatures,
                  contains(const FontFeature.tabularFigures()),
                  reason: paragraph.text.toPlainText(),
                );
              }
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final width in [390.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('open chart skeletons keep their size at $width x$scale', (
        tester,
      ) async {
        final controller = _Controller();
        addTearDown(controller.dispose);
        final api = _Api();
        await _pump(
          tester,
          StatsScreen(api: api, controller: controller, clock: () => _today),
          width: width,
          scale: scale,
        );
        await _expand(tester, 'Activity');
        await _expand(tester, 'Work ahead');
        final activity = find.byKey(
          const PageStorageKey('recall_stats_disclosure_activity'),
        );
        final forecast = find.byKey(
          const PageStorageKey('recall_stats_disclosure_forecast'),
        );
        final activitySize = tester.getSize(activity);
        final forecastSize = tester.getSize(forecast);
        expect(
          tester
              .widget<Focus>(find.byKey(const Key('heatmap_focus')))
              .focusNode!
              .canRequestFocus,
          isFalse,
        );
        api.complete();
        await tester.pumpAndSettle();
        expect(tester.getSize(activity), activitySize);
        expect(tester.getSize(forecast), forecastSize);
        expect(
          tester
              .widget<Focus>(find.byKey(const Key('heatmap_focus')))
              .focusNode!
              .canRequestFocus,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  // Opt-in evidence capture; normal test runs never create or update goldens.
  if (Platform.environment['PORT_STATS_CAPTURE'] case final String phase) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('capture $phase at $width', (tester) async {
        final sdk =
            Platform.environment['RECALL_FLUTTER_ROOT'] ?? '.tools/flutter';
        final font = FontLoader('Roboto')
          ..addFont(
            Future.value(
              ByteData.view(
                File(
                  '$sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
                ).readAsBytesSync().buffer,
              ),
            ),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(
              ByteData.view(
                File(
                  '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ).readAsBytesSync().buffer,
              ),
            ),
          );
        await icons.load();
        final controller = _Controller();
        addTearDown(controller.dispose);
        Future<void> capture(String scene) async {
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(const Key('stats_capture')),
            matchesGoldenFile(
              '../.tmp/port-stats/$phase/${width.toInt()}-$scene.png',
            ),
          );
        }

        final api = _Api()..complete();
        await _pump(
          tester,
          StatsScreen(api: api, controller: controller, clock: () => _today),
          width: width,
        );
        await capture('stats-top');
        await _expand(tester, 'Activity');
        await tester.ensureVisible(find.byType(ReviewHeatmap));
        await capture('activity-open');
        await _expand(tester, 'Activity');
        await _expand(tester, 'Work ahead');
        await tester.ensureVisible(find.byType(DueForecastChart));
        await capture('work-ahead-open');

        final loading = _Api();
        await _pump(
          tester,
          StatsScreen(
            api: loading,
            controller: controller,
            clock: () => _today,
          ),
          width: width,
          settle: false,
        );
        await capture('loading');
        loading.complete();
        await tester.pumpAndSettle();
      });
    }
  }
}

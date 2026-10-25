import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/due_forecast_chart.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/review_heatmap.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  for (final lastCard in [false, true]) {
    _testWidgets('rating and undo update live feedback (last: $lastCard)', (
      tester,
    ) async {
      final controller = _Controller(lastCard: lastCard);
      addTearDown(controller.dispose);
      await _pump(tester, StudyScreen(controller: controller));
      await _tap(tester, find.text('Show answer'));
      final saved = controller.save = Completer<void>();
      await _tap(tester, find.text('Good'));
      expect(find.bySemanticsLabel('0 cards reviewed this session'), findsOne);
      saved.complete();
      await tester.pumpAndSettle();
      final status = find.bySemanticsLabel(
        lastCard
            ? 'Reviewed 1 card this session.'
            : '1 card reviewed this session',
      );
      expect(
        tester
            .getSemantics(status)
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      final undo = lastCard
          ? find.text('Undo last rating')
          : find.byTooltip('Undo');
      await _tap(tester, undo);
      final restored = find.bySemanticsLabel('0 cards reviewed this session');
      await tester.ensureVisible(restored);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(restored)
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      expect(controller.state.showBack, isFalse);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  _testWidgets(
    'Study TalkBack traversal follows actions, question and answer',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await _pump(tester, StudyScreen(controller: controller));
      final traversal = tester.semantics.simulatedAccessibilityTraversal().map((
        node,
      ) {
        final data = node.getSemanticsData();
        return '${data.label} ${data.tooltip}';
      }).toList();
      var previous = -1;
      for (final label in [
        'Like it · keep this style',
        'Don’t like it · hide until Sunday review',
        'Flag for deletion',
        'More options',
        'Synthetic question',
        'Show answer',
      ]) {
        final index = traversal.indexWhere((text) => text.contains(label));
        expect(index, greaterThan(previous), reason: '$label in $traversal');
        previous = index;
      }
    },
  );

  _testWidgets('forecast exposes dated counts without decorative axis labels', (
    tester,
  ) async {
    await _pump(
      tester,
      DueForecastChart(
        days: [
          ForecastDay(date: DateTime(2026, 10, 23), index: 0, count: 3),
          ForecastDay(date: DateTime(2026, 10, 24), index: 1, count: 0),
          ForecastDay(date: DateTime(2026, 10, 25), index: 2, count: 1),
        ],
      ),
    );
    final chart = find.bySemanticsLabel(
      'Due forecast. Today: 3 cards due; Oct 24, 2026: 0 cards due; Oct 25, 2026: 1 card due.',
    );
    expect(
      tester.getSemantics(chart).getSemanticsData().flagsCollection.isImage,
      isTrue,
    );
    expect(find.bySemanticsLabel('Now'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _testWidgets('heatmap groups dated review counts by week for TalkBack', (
    tester,
  ) async {
    await _pump(
      tester,
      ReviewHeatmap(
        days: [
          for (var index = 0; index < 8; index++)
            HeatmapDay(
              date: DateTime(2026, 10, 18 + index),
              count: index,
              level: index == 0 ? 0 : 1,
            ),
        ],
      ),
    );
    final weeks = find.bySemanticsLabel(RegExp(r'^Review activity, week of '));
    expect(weeks, findsNWidgets(2));
    final first = tester.getSemantics(weeks.first).getSemanticsData();
    expect(first.label, contains('Oct 18, 2026: 0 reviews'));
    expect(first.label, contains('Oct 19, 2026: 1 review;'));
    expect(first.label, contains('Oct 24, 2026: 6 reviews.'));
    expect(first.flagsCollection.isImage, isTrue);
    expect(
      tester.getSemantics(weeks.last).getSemanticsData().label,
      'Review activity, week of Oct 25, 2026. Oct 25, 2026: 7 reviews.',
    );
    expect(find.bySemanticsLabel('2026-10-18 · 0'), findsNothing);
    expect(find.bySemanticsLabel('Less'), findsNothing);
    expect(find.bySemanticsLabel('More'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final screen in ['Study', 'Decks', 'Read', 'Stats', 'Settings']) {
    _testWidgets('$screen fits 360dp at 200% with readable controls', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = _Controller();
      final prefs = _Prefs();
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      final now = DateTime.now();
      final api = FakeRecallApi([], decks: controller.state.decks)
        ..deckCounts = {1: (due: 1234, neu: 56), 2: (due: 2, neu: 1)}
        ..reviewLog = [
          ReviewLogEntry(
            at: now,
            rating: 3,
            stateAfter: 2,
            dueAfter: now.add(const Duration(days: 30)),
          ),
        ]
        ..dueDates = [now]
        ..conceptNodes = const [
          ConceptNodeInfo(
            nodeId: 'synthetic',
            title: 'Synthetic reading topic',
            module: 'Synthetic module',
          ),
        ]
        ..conceptPages = [
          ConceptPage(
            nodeId: 'synthetic',
            title: 'Synthetic reading topic for large text',
            bodyHtml: 'Synthetic paragraph.',
            updatedAt: now,
          ),
        ];
      final child = switch (screen) {
        'Study' => StudyScreen(controller: controller),
        'Decks' => DecksScreen(
          controller: controller,
          api: api,
          onStudyDeck: (_) {},
        ),
        'Read' => ReadScreen(
          api: api,
          libraryFirst: true,
          onOpenPrimer: (_, _) async {},
        ),
        'Stats' => StatsScreen(api: api, controller: controller),
        _ => SettingsScreen(prefs: prefs, controller: controller),
      };
      await _pump(tester, child);
      _expectReadable(tester);
      await captureVisual(tester, 'android-a11y-${screen.toLowerCase()}');
      switch (screen) {
        case 'Study':
          final session = find.widgetWithText(TextButton, '0 due · 2 new');
          expect(
            tester.getSize(session).shortestSide,
            greaterThanOrEqualTo(48),
          );
          await _tap(tester, find.text('Show answer'));
          for (final label in ['Again', 'Hard', 'Good', 'Easy']) {
            final button = find.widgetWithText(FilledButton, label);
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            expect(
              tester.getSize(button).shortestSide,
              greaterThanOrEqualTo(48),
            );
            final data = tester.getSemantics(button).getSemanticsData();
            expect(data.flagsCollection.isButton, isTrue);
            expect(data.hasAction(SemanticsAction.tap), isTrue);
          }
        case 'Decks':
          await _scrollTo(tester, find.text('Optional curricula'));
          final toggle = find.byType(ExpansionTile);
          final collapsed = tester
              .getSemantics(find.text('Optional curricula'))
              .getSemanticsData();
          expect(collapsed.hint, 'Collapsed');
          expect(collapsed.hasAction(SemanticsAction.tap), isTrue);
          expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
          await tester.tap(find.text('Optional curricula'));
          await tester.pumpAndSettle();
          expect(
            tester
                .getSemantics(find.text('Optional curricula'))
                .getSemanticsData()
                .hint,
            'Expanded',
          );
          await _scrollTo(
            tester,
            find.text('Opt-in  ›  Synthetic optional curriculum'),
          );
        case 'Read':
          await _scrollTo(
            tester,
            find.byKey(const Key('recall_primer_search')),
          );
          await tester.enterText(
            find.byKey(const Key('recall_primer_search')),
            'Synthetic',
          );
          await tester.pumpAndSettle();
          await _scrollTo(
            tester,
            find.text('Synthetic reading topic for large text'),
          );
          final clear = find.byTooltip('Clear search');
          await tester.ensureVisible(clear);
          expect(tester.getSize(clear).shortestSide, greaterThanOrEqualTo(48));
        case 'Stats':
          for (final title in [
            'Young and mature cards',
            'Activity',
            'Work ahead',
            'Concepts to reinforce',
            'Current session',
          ]) {
            await _scrollTo(tester, find.text(title));
            await tester.tap(find.text(title));
            await tester.pumpAndSettle();
            _expectReadable(tester);
          }
          await _scrollTo(tester, find.text('New left'));
        case 'Settings':
          await _scrollTo(tester, find.text('Per-deck new-card limits'));
          await tester.tap(find.text('Per-deck new-card limits'));
          await tester.pumpAndSettle();
          await _scrollTo(tester, find.text('Synthetic layout practice deck'));
      }
      _expectReadable(tester);
      await captureVisual(
        tester,
        'android-a11y-${screen.toLowerCase()}-details',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Use the SDK's Android fonts rather than the test runner's block font.
  // flutter_tester lives under artifacts/engine/<host>; fonts are siblings of
  // engine in every desktop Flutter SDK. No downloads or app data are needed.
  await tester.runAsync(() async {
    final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
    for (final (family, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('Roboto', 'Roboto-Medium.ttf'),
      ('Roboto', 'Roboto-Bold.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(
          File(
            '${artifacts.path}/material_fonts/$file',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: const Key('visual_benchmark_boundary'),
        child: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    150,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  _expectReadable(tester);
}

void _expectReadable(WidgetTester tester) {
  expect(tester.takeException(), isNull);
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: 'Truncated: ${paragraph.text.toPlainText()}',
    );
  }
}

// Presentation-only state: no persistence, accounts or network services.
class _Controller extends ChangeNotifier implements ReviewController {
  _Controller({bool lastCard = false}) {
    state = ReviewState(
      loading: false,
      decks: const [
        DeckRow(deckId: 1, name: 'Synthetic layout practice deck'),
        DeckRow(deckId: 2, name: 'Opt-in::Synthetic optional curriculum'),
      ],
      queue: [
        testCard(front: 'Synthetic question', back: 'Synthetic answer'),
        if (!lastCard)
          testCard(
            id: 2,
            front: 'Another synthetic question',
            back: 'Another synthetic answer',
          ),
      ],
    );
  }
  @override
  late ReviewState state;
  @override
  final engine = FsrsEngine();
  @override
  Null get currentUser => null;
  @override
  bool canUndo = false;
  @override
  bool get undoInFlight => false;
  @override
  bool rateInFlight = false;
  @override
  bool get currentLiked => false;
  @override
  bool get likeInFlight => false;
  @override
  String? get flagNotice => null;
  Completer<void>? save;
  @override
  void flip() {
    state = state.copyWith(showBack: true);
    notifyListeners();
  }

  @override
  Future<void> rate(Rating rating) async {
    rateInFlight = true;
    notifyListeners();
    await save?.future;
    canUndo = true;
    rateInFlight = false;
    state = state.copyWith(
      index: state.index + 1,
      showBack: false,
      reviewedThisSession: state.reviewedThisSession + 1,
    );
    notifyListeners();
  }

  @override
  Future<void> undo() async {
    canUndo = false;
    state = state.copyWith(
      index: state.index - 1,
      showBack: false,
      reviewedThisSession: state.reviewedThisSession - 1,
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture call: ${invocation.memberName}');
}

class _Prefs extends ChangeNotifier implements RecallPrefsController {
  @override
  RecallPrefs value = const RecallPrefs();
  @override
  Future<void> update(RecallPrefs next) async {
    value = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture call: ${invocation.memberName}');
}

void _testWidgets(
  String name,
  WidgetTesterCallback body, {
  TargetPlatformVariant? variant,
}) {
  testWidgets(name, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  }, variant: variant ?? TargetPlatformVariant.only(TargetPlatform.android));
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';
import 'package:health_anki_flutter/navigation/recall_deep_links.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_acceptance_fixture.dart';

class _NoLinks implements RecallLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get links => const Stream.empty();
}

void main() {
  Future<ReviewController> pumpShell(
    WidgetTester tester, {
    required Size size,
    bool isWeb = true,
    bool nativeAndroid = false,
    bool nativeIos = false,
    double textScale = 1,
    Future<void> Function()? foregroundSync,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.utc(2026, 10, 5, 12);
    final api = SanitizedRecallApi(
      scenario: AcceptanceScenario.rich,
      dataset: SanitizedRecallDataset(
        now: now,
        decks: const [DeckRow(deckId: 1, name: 'ML::Browser parity')],
        cards: [
          ReviewCard(
            id: 1,
            guid: 'web-shell-sanitized-card',
            deckId: 1,
            front: 'What survives a browser resize?',
            back: 'The current study session and library state.',
            hasLatex: false,
            stability: null,
            difficulty: null,
            due: null,
            state: 0,
            reps: 0,
            lapses: 0,
            lastReview: null,
          ),
        ],
        reviews: const [],
        noteTags: const {},
        conceptNodes: const [],
        conceptPages: const [],
      ),
    );
    final prefs = RecallPrefsController(api: api);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      clock: () => now,
    );
    addTearDown(() {
      controller.dispose();
      prefs.dispose();
      api.disposeFixture();
    });
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: AppShell(
          controller: controller,
          api: api,
          prefs: prefs,
          linkSource: _NoLinks(),
          isWeb: isWeb,
          nativeAndroid: nativeAndroid,
          nativeIos: nativeIos,
          foregroundSync: foregroundSync,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> select(WidgetTester tester, String label) async {
    final chrome = find.byType(
      find.byType(NavigationRail).evaluate().isEmpty
          ? NavigationBar
          : NavigationRail,
    );
    await tester.tap(find.descendant(of: chrome, matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop web exposes every destination and shared settings', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(1440, 900));
    expect(find.byType(NavigationBar), findsNothing);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isTrue);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Recall'),
      ),
      findsOneWidget,
    );
    for (final (index, label) in [
      (1, 'Decks'),
      (2, 'Stats'),
      (3, 'Read'),
      (0, 'Study'),
    ]) {
      await select(tester, label);
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        index,
      );
      expect(tester.takeException(), isNull);
    }
    await select(tester, 'Read');
    await tester.tap(find.byKey(const Key('recall_rail_settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('New cards / day'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      3,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone web retains bottom navigation and Study settings menu', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(390, 844));
    expect(find.byType(NavigationRail), findsNothing);
    for (final (index, label) in [
      (1, 'Decks'),
      (2, 'Stats'),
      (3, 'Read'),
      (0, 'Study'),
    ]) {
      await select(tester, label);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        index,
      );
    }
    await tester.tap(find.byTooltip('More options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide web bounds the card beside an independent reading pane', (
    tester,
  ) async {
    final controller = await pumpShell(tester, size: const Size(1440, 900));
    final study = tester.getRect(find.byType(StudyScreen));
    final reading = tester.getRect(
      find.byKey(const Key('recall_reading_column')),
    );
    expect(study.width, lessThanOrEqualTo(640));
    expect(study.height, lessThanOrEqualTo(640));
    expect(reading.width, inInclusiveRange(360, 460));
    expect(reading.left, greaterThan(study.right));
    final current = controller.state.current;
    final search = find.descendant(
      of: find.byKey(const Key('recall_reading_column')),
      matching: find.byKey(const Key('recall_primer_search')),
    );
    await tester.ensureVisible(search);
    await tester.enterText(search, 'A reading search');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pumpAndSettle();
    expect(controller.state.current, same(current));
    expect(controller.state.showBack, isFalse);
    expect(controller.state.reviewedThisSession, 0);
    await tester.tap(find.byType(StudyScreen));
    await tester.pumpAndSettle();
    expect(controller.state.showBack, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.state.showBack, isTrue);
    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(StudyScreen)).width,
      lessThanOrEqualTo(640),
    );
    expect(
      tester.getSize(find.byType(StudyScreen)).height,
      lessThanOrEqualTo(640),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reading search survives narrowing the browser and changing tabs',
    (tester) async {
      await pumpShell(tester, size: const Size(1440, 900));
      final search = find.descendant(
        of: find.byKey(const Key('recall_reading_column')),
        matching: find.byKey(const Key('recall_primer_search')),
      );
      await tester.ensureVisible(search);
      await tester.enterText(search, 'Retained reading query');
      await tester.pumpAndSettle();
      await select(tester, 'Stats');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await select(tester, 'Study');
      expect(
        tester.getSize(find.byKey(const Key('recall_reading_column'))).width,
        0,
      );
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(search).controller!.text,
        'Retained reading query',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resizing preserves the active card, reveal and library search', (
    tester,
  ) async {
    final controller = await pumpShell(tester, size: const Size(1440, 900));
    final studyElement = tester.element(find.byType(StudyScreen));
    final current = controller.state.current;
    await tester.tap(find.text('Show answer'));
    await tester.pumpAndSettle();
    expect(controller.state.showBack, isTrue);

    await select(tester, 'Decks');
    await tester.enterText(
      find.byKey(const Key('recall_deck_search')),
      'Browser parity',
    );
    await tester.pumpAndSettle();
    for (final size in [
      const Size(390, 844),
      const Size(900, 900),
      const Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(StudyScreen)), same(studyElement));
      expect(controller.state.current, same(current));
      expect(controller.state.showBack, isTrue);
      final search = tester.widget<TextField>(
        find.byKey(const Key('recall_deck_search')),
      );
      expect(search.controller!.text, 'Browser parity');
      final rail = find.byType(NavigationRail);
      if (size.width >= 840) {
        expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
        expect(
          tester.widget<NavigationRail>(rail).extended,
          size.width >= 1100,
        );
      } else {
        expect(rail, findsNothing);
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          1,
        );
      }
      expect(tester.takeException(), isNull);
    }
    await select(tester, 'Study');
    expect(controller.state.showBack, isTrue);
    expect(
      find.text('The current study session and library state.'),
      findsOneWidget,
    );
  });

  testWidgets('native Android keeps its existing 600px rail breakpoint', (
    tester,
  ) async {
    await pumpShell(
      tester,
      size: const Size(700, 900),
      isWeb: false,
      nativeAndroid: true,
    );
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isFalse);
    expect(rail.leading, isNull);
    expect(rail.trailing, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large browser text uses the single-column Study view', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(1440, 900), textScale: 2);
    expect(
      tester.getSize(find.byKey(const Key('recall_reading_column'))).width,
      0,
    );
    await tester.ensureVisible(find.text('Show answer'));
    await tester.tap(find.text('Show answer'));
    await tester.pumpAndSettle();
    expect(find.text('Good'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short desktop windows keep navigation and settings reachable', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(900, 360));
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.scrollable, isTrue);
    final read = find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Read'),
    );
    await tester.ensureVisible(read);
    await tester.pumpAndSettle();
    await tester.tap(read);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      3,
    );
    await tester.tap(find.byKey(const Key('recall_rail_settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resume uses the supplied coordinated foreground sync', (
    tester,
  ) async {
    var resumes = 0;
    await pumpShell(
      tester,
      size: const Size(390, 844),
      foregroundSync: () async => resumes++,
    );
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(resumes, 1);
    expect(tester.takeException(), isNull);
  });
}

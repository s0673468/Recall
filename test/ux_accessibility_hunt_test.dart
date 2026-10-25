import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

const _deckName = 'Synthetic layout practice deck';

void main() {
  for (final scale in [1.0, 2.0]) {
    _testWidgets('320dp study retains the full deck title at ${scale}x', (
      tester,
    ) async {
      final controller = _StudyFixture();
      addTearDown(controller.dispose);
      await _pump(tester, StudyScreen(controller: controller), scale: scale);
      final title = find.byKey(const Key('recall_study_title'));
      expect(tester.widget<Text>(title).data, _deckName);
      expect(
        find.descendant(
          of: find.byKey(const Key('recall_study_card_footer')),
          matching: find.text(_deckName),
        ),
        findsOneWidget,
      );
      final paragraph = tester.renderObject<RenderParagraph>(title);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
      for (final label in [
        'Don’t like it · hide until Sunday review',
        'Flag for deletion',
        'More options',
      ]) {
        final button = _iconButton(label);
        expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
        final data = tester.getSemantics(button).getSemanticsData();
        expect(data.label.isEmpty ? data.tooltip : data.label, label);
        expect(data.hasAction(SemanticsAction.tap), isTrue);
      }
    });
  }

  for (final scale in [1.0, 2.0]) {
    _testWidgets(
      'short landscape study can reveal and reach ratings at ${scale}x',
      (tester) async {
        final controller = _StudyFixture();
        addTearDown(controller.dispose);
        await _pump(
          tester,
          StudyScreen(controller: controller),
          size: const Size(568, 220),
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        await _reveal(tester, find.byKey(const Key('recall_study_card')));
        expect(
          tester.getSize(find.byKey(const Key('recall_study_card'))).height,
          greaterThanOrEqualTo(120),
        );
        await _reveal(tester, find.text('Show answer'));
        await tester.tap(find.text('Show answer'));
        await tester.pumpAndSettle();
        expect(controller.state.showBack, isTrue);
        for (final label in ['Again', 'Hard', 'Good', 'Easy']) {
          final button = find.widgetWithText(FilledButton, label);
          await _reveal(tester, button);
          await tester.pumpAndSettle();
          expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
          await tester.tap(button);
          await tester.pumpAndSettle();
        }
        expect(controller.ratings, Rating.values);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final paused in [false, true]) {
    _testWidgets(
      '${paused ? 'Paused session' : 'Load error'} scrolls at 200% in landscape',
      (tester) async {
        final controller = _StudyFixture();
        controller.state = ReviewState(
          loading: false,
          error: paused ? null : 'Synthetic load failure. Please try again.',
          catchUp: paused
              ? const CatchUpView(mode: CatchUpMode.active, dueCount: 100)
              : const CatchUpView(),
        );
        addTearDown(controller.dispose);
        await _pump(
          tester,
          StudyScreen(controller: controller),
          size: const Size(568, 220),
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        final retry = find.widgetWithText(
          FilledButton,
          paused ? 'Reload' : 'Retry',
        );
        await _reveal(tester, retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(controller.refreshes, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    _testWidgets(
      'study keyboard focus follows actions then answer and ratings at ${scale}x',
      (tester) async {
        final controller = _StudyFixture();
        addTearDown(controller.dispose);
        await _pump(tester, StudyScreen(controller: controller), scale: scale);
        for (final finder in [
          _iconButton('Like it · keep this style'),
          _iconButton('Don’t like it · hide until Sunday review'),
          _iconButton('Flag for deletion'),
          _iconButton('More options'),
          find.widgetWithText(TextButton, '0 due · 1 new'),
          find.widgetWithText(FilledButton, 'Show answer'),
        ]) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(_hasFocus(tester, finder), isTrue);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(controller.state.showBack, isTrue);
        // Starting at the first rating, traversal follows reading order.
        Focus.of(tester.element(find.text('Again'))).requestFocus();
        await tester.pump();
        for (final label in ['Again', 'Hard', 'Good', 'Easy']) {
          expect(
            _hasFocus(tester, find.widgetWithText(FilledButton, label)),
            isTrue,
          );
          if (label != 'Easy') {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
          }
        }
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    _testWidgets('flag sheet targets reach 48dp in landscape at ${scale}x', (
      tester,
    ) async {
      final controller = _StudyFixture();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        StudyScreen(controller: controller),
        size: const Size(568, 320),
        scale: scale,
      );
      await tester.tap(_iconButton('More options'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Flag card'));
      await tester.tap(find.text('Flag card'));
      await tester.pumpAndSettle();
      for (final label in [
        'Wrong',
        'Confusing',
        'Too long',
        'Duplicate',
        'Cancel',
      ]) {
        final tile = find.widgetWithText(ListTile, label);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
        expect(
          tester
              .getSemantics(tile)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
      }
      await tester.ensureVisible(find.text('Duplicate'));
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(controller.flags, ['duplicate']);
      expect(tester.takeException(), isNull);
    });
  }

  for (final status in [
    (
      offline: true,
      serverError: false,
      pending: 1234,
      errors: 0,
      label: 'Offline · 1234 waiting to sync',
    ),
    (
      offline: true,
      serverError: true,
      pending: 0,
      errors: 0,
      label: 'Server error',
    ),
    (
      offline: false,
      serverError: false,
      pending: 1234,
      errors: 12,
      label: '1222 syncing · 12 couldn’t sync',
    ),
  ]) {
    _testWidgets(
      '320dp large-text sync status remains readable: ${status.label}',
      (tester) async {
        final controller = _StudyFixture();
        controller.state = controller.state.copyWith(
          offline: status.offline,
          serverError: status.serverError,
          pendingSync: status.pending,
          syncErrors: status.errors,
        );
        addTearDown(controller.dispose);
        await _pump(tester, StudyScreen(controller: controller), scale: 2);
        final text = find.text(status.label);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, isFalse);
        final style = tester.widget<Text>(text).style!;
        expect(
          _contrast(style.color!, UiColors.canvas),
          greaterThanOrEqualTo(4.5),
        );
        final liveRegion = find.ancestor(
          of: text,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.liveRegion == true,
          ),
        );
        expect(liveRegion, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testWidgets('retention slider announces its purpose and percentage', (
    tester,
  ) async {
    final controller = _StudyFixture();
    final prefs = _MemoryPrefs();
    addTearDown(controller.dispose);
    addTearDown(prefs.dispose);
    await _pump(tester, SettingsScreen(prefs: prefs, controller: controller));
    final slider = find.semantics.byPredicate(
      (node) => node.getSemanticsData().flagsCollection.isSlider,
    );
    final data = slider.evaluate().single.getSemanticsData();
    expect(data.label, contains('Desired retention'));
    expect(data.value, '90%');
    tester.semantics.performAction(slider, SemanticsAction.increase);
    await tester.pumpAndSettle();
    expect(prefs.value.desiredRetention, closeTo(.91, .00001));
  });

  for (final size in [const Size(320, 640), const Size(568, 320)]) {
    _testWidgets('settings controls and reminder fit at 200% in $size', (
      tester,
    ) async {
      final controller = _StudyFixture();
      final prefs = _MemoryPrefs();
      final reminder = _ReminderFixture();
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      addTearDown(reminder.dispose);
      await _pump(
        tester,
        SettingsScreen(
          prefs: prefs,
          controller: controller,
          reminder: reminder,
        ),
        size: size,
        scale: 2,
      );
      final scrollable = find.byType(Scrollable).first;
      for (final label in [
        'Increase New cards / day',
        'Decrease New cards / day',
      ]) {
        final button = _iconButton(label);
        await tester.scrollUntilVisible(button, 100, scrollable: scrollable);
        await tester.pumpAndSettle();
        expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
        final data = tester.getSemantics(button).getSemanticsData();
        expect(data.label.isEmpty ? data.tooltip : data.label, label);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }
      expect(prefs.value.newLimitDefault, 20);
      await tester.scrollUntilVisible(
        find.text('23:59'),
        100,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Reminder time'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Per-deck new-card limits'),
        100,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Per-deck new-card limits'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Set override'),
        100,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set override'));
      await tester.pumpAndSettle();
      expect(prefs.value.perDeck[1], 20);
      expect(tester.takeException(), isNull);
    });

    _testWidgets(
      'deck list preserves long names, counts and search at 200% in $size',
      (tester) async {
        final controller = _StudyFixture();
        final api = FakeRecallApi([], decks: controller.state.decks)
          ..deckCounts = {1: (due: 1234, neu: 56)};
        addTearDown(controller.dispose);
        final selected = <int?>[];
        await _pump(
          tester,
          DecksScreen(
            controller: controller,
            api: api,
            onStudyDeck: selected.add,
          ),
          size: size,
          scale: 2,
        );
        await tester.enterText(
          find.byKey(const Key('recall_deck_search')),
          'Synthetic',
        );
        await tester.pumpAndSettle();
        final clear = _iconButton('Clear search');
        expect(tester.getSize(clear).shortestSide, greaterThanOrEqualTo(48));
        final clearData = tester.getSemantics(clear).getSemanticsData();
        expect(
          clearData.label.isEmpty ? clearData.tooltip : clearData.label,
          'Clear search',
        );
        final title = find.text(_deckName);
        await _reveal(tester, title);
        expect(
          tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
          isFalse,
        );
        final row = find.byKey(const ValueKey('recall_deck_row_$_deckName'));
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
        expect(find.text('1234 due · 56 new'), findsOneWidget);
        await tester.ensureVisible(row);
        await tester.tap(title);
        expect(selected, [1]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

void _testWidgets(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      100,
      scrollable: find.byType(Scrollable).first,
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
}

Finder _iconButton(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

bool _hasFocus(WidgetTester tester, Finder finder) {
  final target = tester.element(finder);
  final focused = FocusManager.instance.primaryFocus?.context as Element?;
  var found = focused == target;
  focused?.visitAncestorElements((element) {
    if (element == target) found = true;
    return !found;
  });
  return found;
}

double _contrast(Color a, Color b) {
  final light = a.computeLuminance();
  final dark = b.computeLuminance();
  return (light + .05) / (dark + .05);
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(320, 640),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// Presentation-only doubles: no storage, network, credentials or personal data.
class _StudyFixture extends ChangeNotifier implements ReviewController {
  @override
  ReviewState state = ReviewState(
    loading: false,
    deckFilter: 1,
    decks: const [DeckRow(deckId: 1, name: _deckName)],
    queue: [testCard(front: 'Synthetic question', back: 'Synthetic answer')],
  );
  int refreshes = 0;
  @override
  Future<void> refresh() async {
    refreshes++;
  }

  final ratings = <Rating>[];
  final flags = <String>[];
  @override
  final engine = FsrsEngine();
  @override
  bool get canUndo => false;
  @override
  bool get undoInFlight => false;
  @override
  bool get rateInFlight => false;
  @override
  bool get currentLiked => false;
  @override
  bool get likeInFlight => false;
  @override
  String? get flagNotice => null;
  @override
  Null get currentUser => null;
  @override
  void flip() {
    state = state.copyWith(showBack: true);
    notifyListeners();
  }

  @override
  Future<void> rate(Rating rating) async => ratings.add(rating);
  @override
  Future<void> flag(String reason) async => flags.add(reason);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture call: ${invocation.memberName}');
}

class _MemoryPrefs extends ChangeNotifier implements RecallPrefsController {
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

class _ReminderFixture extends ChangeNotifier
    implements StudyReminderController {
  @override
  StudyReminderSettings get value =>
      const StudyReminderSettings(enabled: true, hour: 23, minute: 59);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture call: ${invocation.memberName}');
}

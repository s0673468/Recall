import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/app/recall_app.dart';
import 'package:health_anki_flutter/app/recall_dependencies.dart';
import 'package:health_anki_flutter/core/widgets/recall_motion.dart';
import 'package:health_anki_flutter/core/widgets/recall_surfaces.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/remediation_rows.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';
import 'package:health_anki_flutter/vendored/src/auth/sign_out_button.dart';

import 'support/recall_test_harness.dart' show FakeRecallApi, testCard;

const _decks = [
  DeckRow(deckId: 7, name: 'Synthetic learning::Geometry'),
  DeckRow(deckId: 8, name: 'Opt-in::Synthetic curriculum'),
];

// Presentation-only fixture: no account, service, or production storage.
class _Controller extends ChangeNotifier implements ReviewController {
  @override
  ReviewState state = ReviewState(
    loading: false,
    decks: _decks,
    queue: [
      testCard(
        deckId: 7,
        front: 'What does a projection measure?',
        back: 'How much of a vector points along a chosen direction.',
      ),
    ],
  );
  @override
  final engine = FsrsEngine();
  @override
  bool get canUndo => undoable;
  bool undoable = false;
  @override
  bool get undoInFlight => false;
  @override
  bool get rateInFlight => false;
  @override
  bool get likeInFlight => false;
  @override
  bool get currentLiked => false;
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LoadingApi extends FakeRecallApi {
  _LoadingApi() : super([]);
  final pages = Completer<List<ConceptPage>>();
  @override
  Future<List<ConceptPage>> fetchConceptPages() => pages.future;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool reducedMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: RepaintBoundary(
        key: const Key('port_colours_capture'),
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            disableAnimations: reducedMotion,
          ),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

Widget _study(_Controller controller) => Scaffold(
  body: Padding(
    padding: const EdgeInsets.all(UiSpacing.md),
    child: StudyScreen(controller: controller, nativeIos: false),
  ),
);

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['RECALL_PORT_COLOURS_CAPTURE'];
  if (output == null) return;
  await expectLater(
    find.byKey(const Key('port_colours_capture')),
    matchesGoldenFile(Uri.file('${Directory.current.path}/$output/$name.png')),
  );
}

int _yellowFilledControls(WidgetTester tester) => tester
    .widgetList<Material>(find.byType(Material))
    .where((material) => material.color == UiColors.primary)
    .length;

void _expectTabular(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  expect(
    text.style?.fontFeatures,
    contains(const FontFeature.tabularFigures()),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (!Platform.environment.containsKey('RECALL_PORT_COLOURS_CAPTURE')) {
      return;
    }
    final sdk = Platform.environment['RECALL_FLUTTER_ROOT']!;
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      final bytes = File(
        '$sdk/bin/cache/artifacts/material_fonts/Roboto-$weight.ttf',
      ).readAsBytesSync();
      await (FontLoader(
        'Roboto',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('control contrast, disabled text and motion tokens are consistent', () {
    final theme = buildRecallTheme();
    expect(UiColors.borderControl, const Color(0xFF72787C));
    expect(UiColors.textDisabled, const Color(0xFF8C9194));
    final contrast =
        (UiColors.borderControl.computeLuminance() + .05) /
        (UiColors.panel.computeLuminance() + .05);
    expect(contrast, greaterThanOrEqualTo(3));
    for (final border in [
      theme.inputDecorationTheme.border,
      theme.inputDecorationTheme.enabledBorder,
      theme.inputDecorationTheme.focusedBorder,
      theme.inputDecorationTheme.disabledBorder,
    ]) {
      expect(border?.borderSide.color, UiColors.borderControl);
    }
    expect(theme.colorScheme.outline, UiColors.borderControl);
    expect(theme.chipTheme.side?.color, UiColors.borderControl);
    expect(
      theme.outlinedButtonTheme.style?.side?.resolve({})?.color,
      UiColors.borderControl,
    );
    expect(theme.dividerColor, UiColors.borderSubtle);
    expect(theme.colorScheme.outlineVariant, UiColors.borderSubtle);
    expect(theme.disabledColor, UiColors.textDisabled);
    for (final style in [
      theme.textButtonTheme.style,
      theme.outlinedButtonTheme.style,
      theme.filledButtonTheme.style,
    ]) {
      expect(
        style?.foregroundColor?.resolve({WidgetState.disabled}),
        UiColors.textDisabled,
      );
    }
    expect(RecallMotion.fast, const Duration(milliseconds: 120));
    expect(RecallMotion.base, const Duration(milliseconds: 200));
    expect(RecallMotion.slow, const Duration(milliseconds: 280));
    expect(RecallMotion.standardCurve, const Cubic(.2, 0, 0, 1));
    expect(RecallMotion.decelerate, const Cubic(0, 0, 0, 1));
    expect(RecallMotion.accelerate, const Cubic(.3, 0, 1, 1));
    expect(RecallMotion.quick, RecallMotion.fast);
    expect(RecallMotion.standard, RecallMotion.base);
    expect(RecallMotion.reverseCurve, RecallMotion.accelerate);
    expect(
      theme.expansionTileTheme.expansionAnimationStyle?.duration,
      RecallMotion.base,
    );
  });

  test('touched presentation files get type sizes from the theme', () {
    for (final path in [
      'lib/app/recall_app.dart',
      'lib/core/widgets/recall_surfaces.dart',
      'lib/features/review/presentation/screens/decks_screen.dart',
      'lib/features/review/presentation/screens/study_screen.dart',
      'lib/features/review/presentation/widgets/rating_bar.dart',
      'lib/features/review/presentation/widgets/remediation_rows.dart',
      'lib/features/settings/presentation/screens/settings_screen.dart',
      'lib/vendored/src/auth/sign_out_button.dart',
    ]) {
      expect(
        RegExp(r'fontSize\s*:').hasMatch(File(path).readAsStringSync()),
        isFalse,
        reason: path,
      );
    }
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('Study ${width.toInt()}dp: one primary and aligned header', (
      tester,
    ) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await _pump(tester, _study(controller), size: Size(width, 844));
      await tester.pumpAndSettle();
      expect(_yellowFilledControls(tester), 1);
      final title = find.byKey(const Key('recall_study_title'));
      final actions = [
        find.byKey(const Key('recall_flag_like')),
        find.byKey(const Key('recall_flag_dislike')),
        find.byKey(const Key('recall_flag_delete')),
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'More options',
        ),
      ];
      for (final action in actions) {
        expect(
          tester.getCenter(action).dy,
          closeTo(tester.getCenter(title).dy, 1),
        );
        final icon = tester.widget<IconButton>(action).icon as Icon;
        expect(icon.size, 20);
        expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
      }
      expect(
        tester.getCenter(actions[1]).dx - tester.getCenter(actions[0]).dx,
        tester.getCenter(actions[2]).dx - tester.getCenter(actions[1]).dx,
      );
      final spacing =
          tester.getCenter(actions[1]).dx - tester.getCenter(actions[0]).dx;
      expect(
        tester.getCenter(actions[3]).dx - tester.getCenter(actions[2]).dx,
        spacing,
      );
      final positions = actions.map(tester.getRect).toList();
      controller.undoable = true;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(actions.map(tester.getRect).toList(), positions);
      expect(find.byTooltip('Undo'), findsOneWidget);
      final strip = find.byKey(const Key('recall_queue_strip'));
      expect(
        tester.getRect(strip).top,
        greaterThan(tester.getCenter(title).dy),
      );
      expect(
        tester.getRect(find.text('0 done')).right,
        closeTo(tester.getRect(strip).right, 1),
      );
      _expectTabular(tester, find.text('0 done'));
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      expect(_yellowFilledControls(tester), 1);
      final hard = find.widgetWithText(FilledButton, 'Hard');
      final button = tester.widget<FilledButton>(hard);
      expect(
        button.style?.foregroundColor?.resolve({}),
        UiColors.textSecondary,
      );
      final shape = button.style?.shape?.resolve({}) as RoundedRectangleBorder;
      expect(shape.side.color, UiColors.borderControl);
      expect(find.text('Good'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Decks ${width.toInt()}dp: counts and shared left edge', (
      tester,
    ) async {
      final controller = _Controller();
      final api = FakeRecallApi([], decks: _decks)
        ..deckCounts = {7: (due: 18, neu: 3), 8: (due: 11, neu: 2)};
      addTearDown(controller.dispose);
      await _pump(
        tester,
        Scaffold(
          body: DecksScreen(
            controller: controller,
            api: api,
            onStudyDeck: (_) {},
          ),
        ),
        size: Size(width, 844),
      );
      await tester.pumpAndSettle();
      expect(_yellowFilledControls(tester), 1);
      for (final label in [
        'Decks',
        'Included in automatic review',
        'Synthetic learning  ›  Geometry',
        'Optional curricula',
      ]) {
        expect(tester.getTopLeft(find.text(label)).dx, UiSpacing.md);
      }
      _expectTabular(tester, find.text('18 due'));
      _expectTabular(tester, find.text('3 new'));
      await tester.tap(find.text('Optional curricula'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Opt-in  ›  Synthetic curriculum')).dx,
        UiSpacing.md,
      );
      _expectTabular(tester, find.text('11 due'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Settings ${width.toInt()}dp: neutral values and secondary actions',
      (tester) async {
        final controller = _Controller();
        final api = FakeRecallApi([], decks: _decks);
        final prefs = RecallPrefsController(api: api);
        addTearDown(controller.dispose);
        addTearDown(prefs.dispose);
        await _pump(
          tester,
          SettingsScreen(prefs: prefs, controller: controller),
          size: Size(width, 844),
        );
        await tester.pumpAndSettle();
        // Settings saves immediately: the slider and selected chip are the
        // permitted selection accents; there is no primary submit button.
        expect(_yellowFilledControls(tester), 0);
        final retention = find.text(
          '${(prefs.value.desiredRetention * 100).round()}%',
        );
        expect(
          tester.widget<Text>(retention).style?.color,
          UiColors.textPrimary,
        );
        _expectTabular(tester, retention);
        _expectTabular(tester, find.text('${prefs.value.newLimitDefault}'));
        final increase = tester.widget<IconButton>(
          find.byWidgetPredicate(
            (widget) =>
                widget is IconButton &&
                widget.tooltip == 'Increase New cards / day',
          ),
        );
        expect(increase.color, UiColors.textSecondary);
        expect(
          tester.widget<Slider>(find.byType(Slider)).activeColor,
          UiColors.primary,
        );
        await tester.tap(find.text('Per-deck new-card limits'));
        await tester.pumpAndSettle();
        final setOverride = find.text('Set override').first;
        await tester.ensureVisible(setOverride);
        expect(
          Theme.of(
            tester.element(setOverride),
          ).textButtonTheme.style?.foregroundColor?.resolve({}),
          UiColors.textSecondary,
        );
        expect(api.savedRecallPrefs, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('section heading, helper and reread row share a left edge', (
    tester,
  ) async {
    final page = ConceptPage(
      nodeId: 'synthetic',
      title: 'Synthetic primer',
      bodyHtml: 'Synthetic body',
      updatedAt: DateTime.utc(2026),
    );
    await _pump(
      tester,
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(UiSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const RecallSectionLabel(title: 'Section', subtitle: 'Helper'),
              RereadRow(page: page, onTap: () {}),
              const RecallMetricStrip(metrics: [RecallMetric('Due', '18')]),
              SignOutButton(onSignOut: () async {}),
            ],
          ),
        ),
      ),
    );
    expect(tester.getTopLeft(find.text('Section')).dx, UiSpacing.md);
    expect(tester.getTopLeft(find.text('Helper')).dx, UiSpacing.md);
    final reread = find.byIcon(Icons.refresh_outlined);
    expect(tester.getTopLeft(reread).dx, UiSpacing.md);
    expect(tester.widget<Icon>(reread).color, UiColors.textMuted);
    expect(
      tester
          .widget<Text>(find.text('Reread: Synthetic primer'))
          .style
          ?.fontSize,
      buildRecallTheme().textTheme.bodyLarge?.fontSize,
    );
    _expectTabular(tester, find.text('18'));
    expect(find.byIcon(Icons.logout_outlined), findsOneWidget);
    expect(tester.widget<Icon>(find.byIcon(Icons.logout_outlined)).size, 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup uses the outlined book and neutral loading feedback', (
    tester,
  ) async {
    final pending = Completer<RecallDependencies>();
    await tester.pumpWidget(RecallBootstrapApp(loader: () => pending.future));
    expect(find.byIcon(Icons.auto_stories_outlined), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.auto_stories_outlined)).color,
      UiColors.textSecondary,
    );
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .color,
      UiColors.textMuted,
    );
    expect(
      tester.widget<Text>(find.text('Recall')).style?.fontSize,
      buildRecallTheme().textTheme.headlineMedium?.fontSize,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'motion durations collapse instantly and sheets use shared timing',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await _pump(tester, _study(controller));
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(find.text('Options')))!;
      expect(route.transitionDuration, RecallMotion.slow);
      expect(route.reverseTransitionDuration, RecallMotion.base);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await _pump(
        tester,
        Builder(
          builder: (context) {
            for (final duration in [
              RecallMotion.fast,
              RecallMotion.base,
              RecallMotion.slow,
            ]) {
              expect(RecallMotion.duration(context, duration), Duration.zero);
            }
            return const SizedBox.shrink();
          },
        ),
        reducedMotion: true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 1280.0]) {
    testWidgets('fixture captures ${width.toInt()}dp', (tester) async {
      final controller = _Controller();
      final api = FakeRecallApi([], decks: _decks)
        ..deckCounts = {7: (due: 18, neu: 3), 8: (due: 11, neu: 2)};
      final prefs = RecallPrefsController(api: api);
      addTearDown(controller.dispose);
      addTearDown(prefs.dispose);
      final size = Size(width, 844);
      await _pump(tester, _study(controller), size: size);
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-study-revealed');

      await _pump(
        tester,
        Scaffold(
          body: DecksScreen(
            controller: controller,
            api: api,
            onStudyDeck: (_) {},
          ),
        ),
        size: size,
      );
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-decks');

      await _pump(
        tester,
        SettingsScreen(prefs: prefs, controller: controller),
        size: size,
      );
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-settings');

      final loading = _LoadingApi();
      await _pump(
        tester,
        Scaffold(
          body: ReadScreen(api: loading, store: LocalReviewStore()),
        ),
        size: size,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _capture(tester, '${width.toInt()}-read-loading');
      await tester.pumpWidget(const SizedBox.shrink());
      loading.pages.complete([]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

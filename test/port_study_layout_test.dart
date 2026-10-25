import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/widgets/recall_surfaces.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';
import 'package:health_anki_flutter/vendored/src/auth/auth_gate.dart';

import 'support/recall_test_harness.dart' show testCard;

const _decks = [DeckRow(deckId: 7, name: 'Synthetic learning::Geometry')];
const _front = 'What does a projection measure?';
const _back = 'How much of a vector points along a chosen direction.';
const _error =
    'Synthetic sign-in failure. The request could not be completed. '
    'Try again when your connection is available. '
    'This deliberately long fixture checks wrapping inside the card.';

// Only presentation state is changed: no service, storage, or account exists.
class _StudyController extends ChangeNotifier implements ReviewController {
  _StudyController({int cardState = 0})
    : state = ReviewState(
        loading: false,
        decks: _decks,
        queue: [
          testCard(deckId: 7, state: cardState, front: _front, back: _back),
        ],
      );

  @override
  ReviewState state;
  @override
  bool get canUndo => false;
  @override
  bool get undoInFlight => false;
  @override
  bool get rateInFlight => false;
  @override
  bool get likeInFlight => false;
  @override
  bool get currentLiked => false;
  @override
  String? flagNotice;

  void update(ReviewState value) {
    state = value;
    notifyListeners();
  }

  @override
  void flip() => update(state.copyWith(showBack: true));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountsApi implements RecallApi {
  final counts = Completer<Map<int, ({int due, int neu})>>();

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() => counts.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AuthFeedback extends ChangeNotifier {
  String? error;
  String? notice;

  late final model = AuthGateModel(
    source: this,
    submitting: () => false,
    errorText: () => error,
    noticeText: () => notice,
    signIn: ({required email, required password}) async {},
  );

  void show({String? error, String? notice}) {
    this.error = error;
    this.notice = notice;
    notifyListeners();
  }
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
        key: const Key('port_study_capture'),
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

Widget _study(_StudyController controller) => Scaffold(
  body: Padding(
    padding: const EdgeInsets.all(16),
    child: StudyScreen(controller: controller, nativeIos: false),
  ),
);

Finder get _card => find.byKey(const Key('recall_study_card'));
Finder get _footer => find.byKey(const Key('recall_study_card_footer'));

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['RECALL_PORT_STUDY_CAPTURE'];
  if (output == null) return;
  await expectLater(
    find.byKey(const Key('port_study_capture')),
    matchesGoldenFile(Uri.file('${Directory.current.path}/$output/$name.png')),
  );
}

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final state in [0, 1, 2, 3]) {
      testWidgets('360dp ${scale}x state $state: footer and frame stay put', (
        tester,
      ) async {
        final controller = _StudyController(cardState: state);
        addTearDown(controller.dispose);
        await _pump(
          tester,
          _study(controller),
          size: const Size(360, 800),
          scale: scale,
        );
        await tester.ensureVisible(find.text('Show answer'));
        final frame = tester.getRect(_card);
        expect(_footer, findsOneWidget);
        final footer = tester.getRect(_footer);
        expect(
          find.descendant(
            of: _footer,
            matching: find.text('Synthetic learning › Geometry'),
          ),
          findsOneWidget,
        );
        final deckText = find.descendant(
          of: _footer,
          matching: find.text('Synthetic learning › Geometry'),
        );
        expect(
          tester.renderObject<RenderParagraph>(deckText).didExceedMaxLines,
          isFalse,
        );
        expect(
          find.descendant(
            of: _footer,
            matching: find.text(state == 0 ? 'New' : 'Review'),
          ),
          findsOneWidget,
        );
        expect(find.text('Good'), findsNothing);
        await tester.tap(find.text('Show answer'));
        await tester.pump();
        expect(tester.getRect(_card), frame);
        expect(tester.getRect(_footer), footer);
        await tester.pumpAndSettle();
        expect(tester.getRect(_card), frame);
        expect(tester.getRect(_footer), footer);
        expect(find.text('Show answer'), findsNothing);
        expect(find.text('Good'), findsOneWidget);
        expect(find.text(_back), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('360dp ${scale}x: sync status never moves the card', (
      tester,
    ) async {
      final controller = _StudyController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        _study(controller),
        size: const Size(360, 800),
        scale: scale,
      );
      final frame = tester.getRect(_card);
      for (final status in [
        (offline: false, serverError: false, pending: 1, errors: 0),
        (offline: false, serverError: false, pending: 2, errors: 1),
        (offline: true, serverError: false, pending: 2, errors: 0),
        (offline: true, serverError: true, pending: 0, errors: 0),
        (offline: false, serverError: false, pending: 0, errors: 0),
      ]) {
        controller.update(
          controller.state.copyWith(
            offline: status.offline,
            serverError: status.serverError,
            pendingSync: status.pending,
            syncErrors: status.errors,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(_card), frame);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('360dp ${scale}x: deck rows reserve their loading counts', (
      tester,
    ) async {
      final controller = _StudyController();
      final api = _CountsApi();
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
        size: const Size(360, 800),
        scale: scale,
      );
      final row = find.byType(RecallListRow).first;
      final before = tester.getRect(row);
      api.counts.complete({7: (due: 18, neu: 3)});
      await tester.pumpAndSettle();
      expect(tester.getRect(row), before);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '390dp ${scale}x: sign-in feedback stays below a stationary button',
      (tester) async {
        final feedback = _AuthFeedback();
        addTearDown(feedback.dispose);
        await _pump(
          tester,
          AuthGate(model: feedback.model, appName: 'Recall'),
          scale: scale,
        );
        final button = find.widgetWithText(FilledButton, 'Sign in');
        final before = tester.getRect(button);
        feedback.show(error: _error);
        await tester.pumpAndSettle();
        expect(tester.getRect(button), before);
        expect(
          tester.getTopLeft(find.text(_error)).dy,
          greaterThan(before.bottom),
        );
        final errorRect = tester.getRect(find.text(_error));
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(_error))
              .didExceedMaxLines,
          isFalse,
        );
        expect(errorRect.left, greaterThanOrEqualTo(24));
        expect(errorRect.right, lessThanOrEqualTo(390 - 24));
        expect(errorRect.height, greaterThan(20));
        final errorScroll = find
            .ancestor(of: find.text(_error), matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(errorScroll).position;
        expect(position.maxScrollExtent, greaterThan(0));
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        expect(tester.getRect(button), before);
        feedback.show(notice: 'Synthetic notice: try again.');
        await tester.pumpAndSettle();
        expect(tester.getRect(button), before);
        expect(find.text(_error), findsNothing);
        expect(find.text('Synthetic notice: try again.'), findsOneWidget);
        feedback.show();
        await tester.pumpAndSettle();
        expect(tester.getRect(button), before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final layout in [
    (width: 320.0, scale: 2.0),
    (width: 1280.0, scale: 1.0),
  ]) {
    for (final newCount in [0, 3]) {
      testWidgets(
        'deck loading ${layout.width}dp ${layout.scale}x, $newCount new',
        (tester) async {
          final controller = _StudyController();
          final api = _CountsApi();
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
            size: Size(layout.width, 844),
            scale: layout.scale,
          );
          await tester.enterText(
            find.byKey(const Key('recall_deck_search')),
            'Geometry',
          );
          await tester.pump();
          final row = find.byType(RecallListRow).first;
          final before = tester.getRect(row);
          api.counts.complete({7: (due: 18, neu: newCount)});
          await tester.pumpAndSettle();
          expect(tester.getRect(row), before);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'long answers scroll above a fixed footer and unknown decks have a label',
    (tester) async {
      final controller = _StudyController();
      controller.update(
        controller.state.copyWith(
          decks: [],
          queue: [
            testCard(front: _front, back: List.filled(50, _back).join(' ')),
          ],
        ),
      );
      addTearDown(controller.dispose);
      await _pump(tester, _study(controller));
      expect(
        find.descendant(of: _footer, matching: find.text('Deck')),
        findsOneWidget,
      );
      final footer = tester.getRect(_footer);
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      final cardScroll = find
          .descendant(of: _card, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(cardScroll).position;
      expect(position.maxScrollExtent, greaterThan(0));
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(tester.getRect(_footer), footer);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion expands optional decks immediately', (
    tester,
  ) async {
    final controller = _StudyController();
    controller.update(
      controller.state.copyWith(
        decks: const [DeckRow(deckId: 8, name: 'Opt-in::Synthetic curriculum')],
      ),
    );
    final api = _CountsApi()..counts.complete({8: (due: 1, neu: 0)});
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
      reducedMotion: true,
    );
    final tile = tester.widget<ExpansionTile>(find.byType(ExpansionTile));
    expect(tile.expansionAnimationStyle, AnimationStyle.noAnimation);
    await tester.tap(find.text('Optional curricula'));
    await tester.pump();
    expect(find.text('Opt-in  ›  Synthetic curriculum'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion removes the notice and Study sheet transitions', (
    tester,
  ) async {
    final controller = _StudyController();
    addTearDown(controller.dispose);
    await _pump(tester, _study(controller), reducedMotion: true);
    controller.flagNotice = 'Synthetic saved confirmation';
    controller.notifyListeners();
    await tester.pump();
    final switcher = find
        .ancestor(
          of: find.text('Synthetic saved confirmation'),
          matching: find.byType(AnimatedSwitcher),
        )
        .first;
    expect(tester.widget<AnimatedSwitcher>(switcher).duration, Duration.zero);
    await tester.tap(find.byTooltip('More options'));
    await tester.pump();
    final sheetContext = tester.element(find.text('Options'));
    final route = ModalRoute.of(sheetContext)!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    await tester.tap(find.text('Flag card'));
    await tester.pumpAndSettle();
    final flagRoute = ModalRoute.of(
      tester.element(find.text('Flag this card')),
    )!;
    expect(flagRoute.transitionDuration, Duration.zero);
    expect(flagRoute.reverseTransitionDuration, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  // The same production widgets and synthetic states capture both revisions.
  // Capture is opt-in; ordinary tests never write artifacts or contact services.
  for (final width in [390.0, 1280.0]) {
    testWidgets('fixture captures ${width.toInt()}dp', (tester) async {
      if (Platform.environment.containsKey('RECALL_PORT_STUDY_CAPTURE')) {
        // Match the production system sans with Flutter's bundled Roboto.
        final sdk = Platform.environment['RECALL_FLUTTER_ROOT']!;
        final font = File(
          '$sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
        );
        await (FontLoader('Roboto')..addFont(
              Future.value(ByteData.sublistView(font.readAsBytesSync())),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      final controller = _StudyController();
      final feedback = _AuthFeedback();
      addTearDown(controller.dispose);
      addTearDown(feedback.dispose);
      final size = Size(width, 844);
      await _pump(tester, _study(controller), size: size);
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-study-front');
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-study-revealed');
      controller.update(controller.state.copyWith(pendingSync: 1));
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-study-syncing');

      final api = _CountsApi();
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
      await _capture(tester, '${width.toInt()}-decks-loading');
      api.counts.complete({7: (due: 18, neu: 3)});
      await tester.pumpAndSettle();

      await _pump(
        tester,
        AuthGate(model: feedback.model, appName: 'Recall'),
        size: size,
      );
      feedback.show(error: _error);
      await tester.pumpAndSettle();
      await _capture(tester, '${width.toInt()}-signin-error');
      expect(tester.takeException(), isNull);
    });
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

// Presentation fixture only: no account or service is accessed.
class _Controller extends ChangeNotifier implements ReviewController {
  @override
  ReviewState state = ReviewState(
    loading: false,
    decks: const [DeckRow(deckId: 1, name: 'Synthetic study')],
    queue: [
      testCard(id: 1, front: 'First question', back: 'First answer'),
      testCard(
        id: 2,
        front: 'A longer second question that wraps on a phone.',
        back: 'Second answer',
      ),
    ],
  );
  @override
  bool get canUndo => state.index > 0;
  @override
  bool get undoInFlight => false;
  @override
  bool get rateInFlight => false;
  @override
  bool get likeInFlight => false;
  @override
  bool currentLiked = false;
  @override
  String? flagNotice;

  @override
  void flip() {
    state = state.copyWith(showBack: true);
    notifyListeners();
  }

  @override
  Future<void> rate(Rating rating) async {
    currentLiked = false;
    flagNotice = null;
    state = state.copyWith(
      index: state.index + 1,
      showBack: false,
      reviewedToday: 1,
      reviewedThisSession: 1,
      pendingSync: 1,
    );
    notifyListeners();
  }

  @override
  Future<void> toggleLike() async {
    currentLiked = !currentLiked;
    flagNotice = 'Liked · saved for Sunday review';
    notifyListeners();
  }

  void showNotice(String? text) {
    flagNotice = text;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['RECALL_REVIEW_CAPTURE'];
  if (output == null) return;
  await expectLater(
    find.byKey(const Key('study_capture')),
    matchesGoldenFile(Uri.file('$output/$name.png')),
  );
}

void main() {
  setUpAll(() async {
    if (!Platform.environment.containsKey('RECALL_REVIEW_CAPTURE')) return;
    final sdk = Platform.environment['RECALL_FLUTTER_ROOT']!;
    final font = File(
      '$sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
    );
    await (FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync()))))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(320, 740), 1.0),
    (const Size(360, 740), 2.0),
  ]) {
    testWidgets(
      '${size.width}dp ${scale}x keeps controls, count and card bounds stable between frames',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _Controller();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildRecallTheme(),
            home: RepaintBoundary(
              key: const Key('study_capture'),
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: StudyScreen(
                      controller: controller,
                      nativeIos: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const Key('recall_study_card'));
        final frame = tester.getRect(card);
        final like = find.byKey(const Key('recall_flag_like'));
        final dislike = find.byKey(const Key('recall_flag_dislike'));
        final undo = find.byKey(const Key('recall_study_undo'));
        expect(undo, findsOneWidget);
        expect(tester.widget<IconButton>(undo).onPressed, isNull);
        expect(like.hitTestable(), findsOneWidget);
        expect(dislike.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(like).right,
          lessThanOrEqualTo(tester.getRect(dislike).left),
        );
        expect(tester.getSize(like).shortestSide, greaterThanOrEqualTo(48));
        await _capture(tester, '${size.width.toInt()}-${scale}x-front');

        await tester.tap(like);
        await tester.pump();
        expect(find.byIcon(Icons.thumb_up), findsOneWidget);
        expect(find.text('0 done'), findsOneWidget);
        expect(find.text('Liked · saved for Sunday review'), findsOneWidget);
        expect(tester.getRect(card), frame);
        await _capture(tester, '${size.width.toInt()}-${scale}x-liked');

        controller.showNotice('Synced reviews cannot be undone');
        for (final elapsed in [0, 16, 50, 120, 250]) {
          await tester.pump(Duration(milliseconds: elapsed));
          expect(find.text('0 done'), findsOneWidget);
          expect(tester.getRect(card), frame);
        }
        controller.showNotice(null);
        controller.flip();
        await tester.pump();
        expect(find.text('First answer'), findsOneWidget);
        expect(tester.getRect(card), frame);
        await controller.rate(Rating.good);
        for (final elapsed in [0, 16, 50, 120, 250]) {
          await tester.pump(Duration(milliseconds: elapsed));
          expect(find.text('First answer', skipOffstage: false), findsNothing);
          expect(
            find.text('First question', skipOffstage: false),
            findsNothing,
          );
          expect(
            find.text('A longer second question that wraps on a phone.'),
            findsOneWidget,
          );
          expect(find.text('1 done'), findsOneWidget);
          expect(tester.getRect(card), frame);
        }
        expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        await _capture(tester, '${size.width.toInt()}-${scale}x-next');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

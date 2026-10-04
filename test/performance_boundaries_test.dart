import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

const _mathFront =
    r'<div>Given \(f(x)=\frac{1}{1+e^{-x}}\), show '
    r'\(f\prime(x)=f(x)(1-f(x))\).</div>';
const _mathBack = r'<b>Answer:</b> \(\sum_{i=1}^{n} w_i x_i + b\)';

ReviewCard _card({String front = _mathFront, String back = _mathBack}) =>
    ReviewCard(
      id: 7,
      guid: 'g7',
      deckId: 1,
      front: front,
      back: back,
      hasLatex: true,
      stability: 3,
      difficulty: 5,
      due: DateTime.utc(2026, 10, 1),
      state: 2,
      reps: 3,
      lapses: 0,
      lastReview: DateTime.utc(2026, 9, 28),
    );

/// Drives StudyScreen through metadata-only notifications without the
/// persistence and network machinery of the real controller.
class _MetadataController extends ChangeNotifier implements ReviewController {
  ReviewState _state;
  String? _notice;
  bool _rateInFlight = false;

  _MetadataController(this._state);

  @override
  ReviewState get state => _state;

  void emit(ReviewState next) {
    _state = next;
    notifyListeners();
  }

  @override
  String? get flagNotice => _notice;

  set notice(String? value) {
    _notice = value;
    notifyListeners();
  }

  @override
  bool get rateInFlight => _rateInFlight;

  set rateLocked(bool value) {
    _rateInFlight = value;
    notifyListeners();
  }

  @override
  bool get canUndo => false;

  @override
  bool get undoInFlight => false;

  @override
  int get remediationRevision => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpStudy(WidgetTester tester, _MetadataController c) async {
  tester.view.physicalSize = const Size(411, 914);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: Scaffold(
        body: StudyScreen(controller: c, nativeIos: false),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The composed root span of every mounted face (front first). Pills and math
/// render nested paragraphs, so only each face's outermost paragraph counts.
List<InlineSpan> _faceSpans(WidgetTester tester) {
  final faces = find.byType(CardFace);
  return [
    for (var i = 0; i < faces.evaluate().length; i++)
      tester
          .renderObject<RenderParagraph>(
            find
                .descendant(of: faces.at(i), matching: find.byType(RichText))
                .first,
          )
          .text,
  ];
}

void main() {
  group('study card face rebuild boundary', () {
    testWidgets(
      'sync, notice, and rating-lock ticks reuse the parsed card face',
      (tester) async {
        final controller = _MetadataController(
          ReviewState(loading: false, queue: [_card()], showBack: true),
        );
        addTearDown(controller.dispose);
        await _pumpStudy(tester, controller);

        final mathBefore = tester.widgetList<Math>(find.byType(Math)).toList();
        final spansBefore = _faceSpans(tester);
        expect(mathBefore, isNotEmpty);
        expect(spansBefore, hasLength(2)); // front + back

        controller.emit(controller.state.copyWith(pendingSync: 2));
        await tester.pump();
        expect(find.text('2 syncing'), findsOneWidget);
        controller.notice = 'Hidden until Sunday review';
        await tester.pump();
        controller.rateLocked = true;
        await tester.pump();
        controller.rateLocked = false;
        controller.notice = null;
        controller.emit(controller.state.copyWith(offline: true));
        await tester.pump();
        expect(find.text('Offline · 2 waiting to sync'), findsOneWidget);

        final mathAfter = tester.widgetList<Math>(find.byType(Math)).toList();
        final spansAfter = _faceSpans(tester);
        expect(mathAfter, hasLength(mathBefore.length));
        for (var i = 0; i < mathBefore.length; i++) {
          expect(identical(mathAfter[i], mathBefore[i]), isTrue);
        }
        for (var i = 0; i < spansBefore.length; i++) {
          expect(identical(spansAfter[i], spansBefore[i]), isTrue);
        }
      },
    );

    testWidgets('flipping a plain front keeps it; a cloze front re-renders', (
      tester,
    ) async {
      final controller = _MetadataController(
        ReviewState(loading: false, queue: [_card()]),
      );
      addTearDown(controller.dispose);
      await _pumpStudy(tester, controller);
      final plainFront = _faceSpans(tester).single;

      controller.emit(controller.state.copyWith(showBack: true));
      await tester.pumpAndSettle();
      expect(identical(_faceSpans(tester).first, plainFront), isTrue);

      final cloze = _MetadataController(
        ReviewState(
          loading: false,
          queue: [
            _card(front: 'Capital: {{c1::Paris}}', back: 'France'),
          ],
        ),
      );
      addTearDown(cloze.dispose);
      await _pumpStudy(tester, cloze);
      expect(find.text('[…]'), findsOneWidget);
      cloze.emit(cloze.state.copyWith(showBack: true));
      await tester.pumpAndSettle();
      expect(find.text('[…]'), findsNothing);
      expect(find.text('Paris'), findsOneWidget);
    });

    testWidgets('a content change still re-renders the face', (tester) async {
      final controller = _MetadataController(
        ReviewState(
          loading: false,
          queue: [_card(front: 'Old front', back: 'Back')],
        ),
      );
      addTearDown(controller.dispose);
      await _pumpStudy(tester, controller);
      expect(find.text('Old front'), findsOneWidget);

      controller.emit(
        controller.state.copyWith(
          queue: [_card(front: 'New front', back: 'Back')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old front'), findsNothing);
      expect(find.text('New front'), findsOneWidget);
    });
  });
}

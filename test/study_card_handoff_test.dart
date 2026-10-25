import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

const _firstFront = 'Synthetic first question';
const _firstBack = 'Synthetic first answer';
const _secondFront = 'Synthetic second question';
const _secondBack = 'Synthetic second answer';
const _thirdFront = 'Synthetic third question';

/// Keep the real outbox write, but control both its start and its local ACK.
class _HeldReviewStore extends LocalReviewStore {
  final allowWrite = Completer<void>();
  final committed = Completer<void>();
  final allowAck = Completer<void>();
  int submissions = 0;
  int acknowledgements = 0;

  @override
  Future<int> enqueueReview(
    Map<String, dynamic> entry, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    submissions++;
    await allowWrite.future;
    final count = await super.enqueueReview(
      entry,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
    if (!committed.isCompleted) committed.complete();
    await allowAck.future;
    acknowledgements++;
    return count;
  }

  void release() {
    if (!allowWrite.isCompleted) allowWrite.complete();
    if (!allowAck.isCompleted) allowAck.complete();
  }
}

Future<
  ({ReviewController controller, FakeRecallApi api, _HeldReviewStore store})
>
_pumpStudy(
  WidgetTester tester, {
  Size size = const Size(800, 700),
  double scale = 1,
  bool offline = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = FakeRecallApi([
    testCard(id: 101, front: _firstFront, back: _firstBack),
    testCard(id: 102, front: _secondFront, back: _secondBack),
    testCard(id: 103, front: _thirdFront),
  ]);
  final store = _HeldReviewStore();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    clock: () => DateTime.utc(2026, 10, 25, 12),
  );
  addTearDown(() {
    store.release();
    controller.dispose();
  });
  await controller.load();
  if (offline) {
    // Preserve unsent ratings for the ACK and Undo assertions.
    api.beforeQueue = () async => throw StateError('Synthetic offline fetch');
    await controller.refresh();
    expect(controller.state.offline, isTrue);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: StudyScreen(controller: controller, nativeIos: false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller: controller, api: api, store: store);
}

Future<void> _reveal(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Show answer'));
  await tester.tap(find.text('Show answer'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Good'));
  await tester.pumpAndSettle();
}

void _expectImmediateFront(
  WidgetTester tester,
  String front, {
  required List<String> absent,
}) {
  final question = find.text(front, skipOffstage: false);
  expect(question, findsOneWidget);
  expect(question.hitTestable(), findsOneWidget);
  for (final text in absent) {
    expect(find.text(text, skipOffstage: false), findsNothing);
  }

  // Inspect effective rendered opacity, including any ancestor fade. Merely
  // finding the incoming text would also pass when it is still transparent.
  var opacity = 1.0;
  RenderObject? object = tester.renderObject(question);
  while (object != null) {
    if (object is RenderOpacity) opacity *= object.opacity;
    if (object is RenderAnimatedOpacity) opacity *= object.opacity.value;
    object = object.parent;
  }
  expect(opacity, 1.0, reason: 'The first frame must show the complete front');
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final layout in [
    (name: 'standard', size: const Size(800, 700), scale: 1.0),
    (name: 'short window', size: const Size(800, 360), scale: 1.0),
    (name: 'large text', size: const Size(390, 740), scale: 2.0),
  ]) {
    testWidgets(
      '${layout.name}: local ACK replaces the old card at full opacity in one frame',
      (tester) async {
        final (:controller, :store, api: _) = await _pumpStudy(
          tester,
          size: layout.size,
          scale: layout.scale,
        );
        await _reveal(tester);

        // Both taps arrive before a rebuild can disable the rating controls.
        await tester.tap(find.text('Good'));
        await tester.tap(find.text('Good'));
        await tester.pump();
        expect(store.submissions, 1);
        expect(controller.rateInFlight, isTrue);
        expect(controller.state.current?.id, 101);
        expect(controller.state.showBack, isTrue);
        expect(find.text(_firstBack), findsOneWidget);
        expect(find.text(_secondFront), findsNothing);
        expect(await store.outbox(), isEmpty);

        store.allowWrite.complete();
        await tester.pump();
        expect(store.committed.isCompleted, isTrue);
        final durable = await LocalReviewStore().outbox();
        expect(durable, hasLength(1));
        expect(durable.single['card_id'], 101);
        expect(durable.single['rating'], Rating.good.value);
        expect(store.acknowledgements, 0);
        expect(controller.state.current?.id, 101);
        expect(controller.state.showBack, isTrue);
        expect(find.text(_firstBack), findsOneWidget);
        expect(find.text(_secondFront), findsNothing);

        store.allowAck.complete();
        // No elapsed animation time or settling between ACK and assertion.
        await tester.pump();
        _expectImmediateFront(
          tester,
          _secondFront,
          absent: [_firstFront, _firstBack, _secondBack],
        );
        expect(store.acknowledgements, 1);
        expect(store.submissions, 1);
        expect(controller.state.current?.id, 102);
        expect(controller.state.showBack, isFalse);
        expect(controller.state.reviewedThisSession, 1);
        expect(controller.rateInFlight, isFalse);
        expect(await LocalReviewStore().outbox(), hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Undo restores the front in one frame without an outgoing card', (
    tester,
  ) async {
    final (:controller, :store, api: _) = await _pumpStudy(tester);
    store.release();
    await _reveal(tester);
    await tester.tap(find.text('Good'));
    await tester.pump();
    expect(controller.state.current?.id, 102);
    await _reveal(tester);
    expect(find.text(_secondBack), findsOneWidget);
    expect(controller.canUndo, isTrue);

    await tester.ensureVisible(find.byTooltip('Undo'));
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    _expectImmediateFront(
      tester,
      _firstFront,
      absent: [_firstBack, _secondFront, _secondBack],
    );
    expect(controller.state.current?.id, 101);
    expect(controller.state.showBack, isFalse);
    expect(controller.state.reviewedThisSession, 0);
    expect(await LocalReviewStore().outbox(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('card handoffs proceed while the network sender is held', (
    tester,
  ) async {
    final (:controller, :api, :store) = await _pumpStudy(
      tester,
      offline: false,
    );
    final releaseSender = Completer<void>();
    var sends = 0;
    api.beforeApplyReview = () {
      sends++;
      return releaseSender.future;
    };
    addTearDown(() async {
      if (!releaseSender.isCompleted) releaseSender.complete();
      await tester.runAsync(controller.syncPending);
    });
    store.release();
    await _reveal(tester);
    await tester.tap(find.text('Good'));
    await tester.pump();
    _expectImmediateFront(
      tester,
      _secondFront,
      absent: [_firstFront, _firstBack, _secondBack],
    );
    expect(sends, 1);
    expect(releaseSender.isCompleted, isFalse);
    expect(api.applied, isEmpty);

    await _reveal(tester);
    await tester.tap(find.text('Good'));
    await tester.pump();
    _expectImmediateFront(
      tester,
      _thirdFront,
      absent: [_firstFront, _firstBack, _secondFront, _secondBack],
    );
    expect(controller.state.reviewedThisSession, 2);
    expect(store.submissions, 2);
    expect(store.acknowledgements, 2);
    expect(sends, 1);
    expect(releaseSender.isCompleted, isFalse);
    expect(api.applied, isEmpty);
    expect(
      (await LocalReviewStore().outbox()).map((entry) => entry['card_id']),
      [101, 102],
    );

    releaseSender.complete();
    await tester.runAsync(controller.syncPending);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(api.applied, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });
}

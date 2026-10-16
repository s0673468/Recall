import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/card_face.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import '../tool/fixtures/synthetic_recall_flow.dart';
import '../tool/fixtures/synthetic_study_frame.dart';

const _fixtureWait = Duration(seconds: 10);
const _caseTimeout = Timeout(Duration(seconds: 30));

Future<({SyntheticRecallFlow flow, SyntheticStudyFrameProbe probe})> _fixture(
  WidgetTester tester,
) async {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  // Supabase starts a real JSON isolate even with the in-memory HTTP client.
  // Keep that lifecycle outside the widget binding's fake async clock.
  final flow = (await tester.runAsync(
    () => SyntheticRecallFlow.create(
      cardCount: 20,
      seededOutbox: 0,
      warmCache: false,
    ).timeout(_fixtureWait),
  ))!;
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        try {
          await flow.controller.syncPending().timeout(_fixtureWait);
        } finally {
          await flow.close().timeout(_fixtureWait);
        }
      });
    } finally {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    }
  });
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    await flow.load().timeout(_fixtureWait);
    await flow.selectDeck(1).timeout(_fixtureWait);
  });
  return (flow: flow, probe: SyntheticStudyFrameProbe(flow.controller));
}

Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('real rating advances once before the next card paints', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    final probe = fixture.probe;
    await _mount(tester, probe.screen());
    expect(probe.hasPaintedCard(1), isTrue);
    expect(probe.hasPaintedCard(2), isFalse);

    await tester.runAsync(
      () => fixture.flow.rateFirstGood().timeout(_fixtureWait),
    );
    expect(fixture.flow.controller.state.current?.id, 2);
    expect(
      probe.hasPaintedCard(2),
      isFalse,
      reason: 'Controller advancement alone is not paint',
    );
    probe.requestPaint();
    await tester.pump();
    expect(
      probe.hasPaintedCard(2),
      isFalse,
      reason: 'An incoming zero-opacity frame is not visible',
    );
    probe.requestPaint();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    expect(probe.hasPaintedCard(2), isTrue);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CardFace && widget.cacheKey == '2:front',
      ),
      findsOneWidget,
    );
    expect(fixture.flow.controller.state.reviewedThisSession, 1);
    final pending = (await tester.runAsync(
      () => fixture.flow.store.outbox().timeout(_fixtureWait),
    ))!;
    expect(pending, hasLength(1));
    expect(pending.single['card_id'], 1);
  }, timeout: _caseTimeout);

  testWidgets(
    'a painted status-only root cannot qualify as a study card',
    (tester) async {
      final fixture = await _fixture(tester);
      await _mount(
        tester,
        SyntheticStudyFrame(
          probe: fixture.probe,
          child: const Center(child: Text('Synthetic benchmark ready')),
        ),
      );
      expect(fixture.probe.hasPaintedCard(1), isFalse);
      expect(fixture.probe.hasPaintedCard(2), isFalse);
    },
    timeout: _caseTimeout,
  );

  testWidgets(
    'a completed frame with the old current card cannot qualify card2',
    (tester) async {
      final fixture = await _fixture(tester);
      await _mount(tester, fixture.probe.screen());
      expect(fixture.flow.controller.state.current?.id, 1);
      expect(fixture.probe.hasPaintedCard(1), isTrue);
      expect(fixture.probe.hasPaintedCard(2), isFalse);
    },
    timeout: _caseTimeout,
  );

  for (final opacityKind in ['opacity', 'animated-opacity']) {
    testWidgets(
      'a previously painted next card with quantized-zero $opacityKind is hidden',
      (tester) async {
        final fixture = await _fixture(tester);
        final opacity = ValueNotifier<double>(1);
        addTearDown(opacity.dispose);
        await _mount(
          tester,
          SyntheticStudyFrame(
            probe: fixture.probe,
            child: ValueListenableBuilder<double>(
              valueListenable: opacity,
              builder: (context, value, child) => opacityKind == 'opacity'
                  ? Opacity(opacity: value, child: child)
                  : AnimatedOpacity(
                      opacity: value,
                      duration: Duration.zero,
                      child: child,
                    ),
              child: StudyScreen(
                controller: fixture.flow.controller,
                nativeIos: false,
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => fixture.flow.rateFirstGood().timeout(_fixtureWait),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        fixture.probe.requestPaint();
        await tester.pump();
        expect(fixture.probe.hasPaintedCard(2), isTrue);

        opacity.value = 0.0001;
        await tester.pumpAndSettle();
        expect(fixture.probe.hasPaintedCard(2), isFalse);
      },
      timeout: _caseTimeout,
    );
  }

  for (final hidden in ['opacity', 'offstage', 'outside-viewport']) {
    testWidgets(
      'a mounted production card hidden by $hidden cannot qualify',
      (tester) async {
        final fixture = await _fixture(tester);
        final study = StudyScreen(
          controller: fixture.flow.controller,
          nativeIos: false,
        );
        final child = switch (hidden) {
          'opacity' => Opacity(opacity: 0, child: study),
          'offstage' => Offstage(child: study),
          _ => Transform.translate(offset: const Offset(1000, 0), child: study),
        };
        await _mount(
          tester,
          SyntheticStudyFrame(probe: fixture.probe, child: child),
        );
        expect(find.byType(StudyScreen, skipOffstage: false), findsOneWidget);
        expect(fixture.probe.hasPaintedCard(1), isFalse);
      },
      timeout: _caseTimeout,
    );
  }
}

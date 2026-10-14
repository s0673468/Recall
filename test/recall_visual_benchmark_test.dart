import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';
import 'package:health_anki_flutter/vendored/src/navigation/app_switcher.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Visual benchmark surfaces', () {
    for (final appleMobile in [false, true]) {
      testWidgets(
        'core ${appleMobile ? 'iOS' : 'Android'} surfaces render without overflow',
        (tester) async {
          await loadVisualFonts();
          SharedPreferences.setMockInitialValues({});
          final now = DateTime.now();
          final page = ConceptPage(
            nodeId: 'm00-vector-geometry',
            title: 'Vector geometry primer',
            bodyHtml:
                r'Projection measures one vector along another: \(p = \frac{x \cdot v}{v \cdot v}v\).',
            updatedAt: now,
          );
          final api =
              FakeRecallApi(
                  [
                    testCard(
                      id: 7001,
                      deckId: 1,
                      state: 2,
                      front: r'Why does attention divide by \(\sqrt{d_k}\)?',
                      back:
                          r'It keeps dot-product variance stable as the key dimension grows.<br><br>Formula: \(\operatorname{softmax}(QK^T / \sqrt{d_k})V\).',
                      hasLatex: true,
                    ),
                  ],
                  decks: const [
                    DeckRow(deckId: 1, name: 'ML'),
                    DeckRow(deckId: 2, name: 'Math'),
                    DeckRow(deckId: 3, name: 'Portuguese'),
                  ],
                )
                ..deckCounts = const {
                  1: (due: 18, neu: 3),
                  2: (due: 11, neu: 2),
                  3: (due: 7, neu: 5),
                }
                ..reviewLog = [
                  for (var day = 0; day < 24; day++)
                    ReviewLogEntry(
                      guid: 'g$day',
                      at: now.subtract(Duration(days: day)),
                      rating: day % 5 == 0 ? 1 : 3,
                    ),
                ]
                ..dueDates = [
                  for (var day = 0; day < 14; day++)
                    for (var card = 0; card < (day % 5) + 1; card++)
                      now.add(Duration(days: day)),
                ]
                ..noteTags = const {'g0': 'node::m00-vector-geometry'}
                ..conceptNodes = const [
                  ConceptNodeInfo(
                    nodeId: 'm00-vector-geometry',
                    title: 'Vector geometry',
                    module: 'M00',
                  ),
                ]
                ..conceptPages = [page];
          final controller = ReviewController(
            api: api,
            engine: FsrsEngine(),
            store: LocalReviewStore(),
          );
          final prefs = RecallPrefsController(api: api);
          addTearDown(controller.dispose);
          addTearDown(prefs.dispose);
          await controller.load();
          await prefs.load();

          Future<void> pumpShell({
            required Size size,
            required bool nativeIos,
            required bool nativeAndroid,
            required EdgeInsets padding,
            TextScaler textScaler = TextScaler.noScaling,
          }) async {
            debugDefaultTargetPlatformOverride = nativeIos
                ? TargetPlatform.iOS
                : nativeAndroid
                ? TargetPlatform.android
                : null;
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            await tester.pumpWidget(
              MaterialApp(
                theme: buildRecallTheme(),
                home: RepaintBoundary(
                  key: const Key('visual_benchmark_boundary'),
                  child: MediaQuery(
                    data: MediaQueryData(
                      size: size,
                      padding: padding,
                      textScaler: textScaler,
                    ),
                    child: AppShell(
                      key: ValueKey(
                        'visual-shell-$size-$nativeIos-$nativeAndroid-$textScaler',
                      ),
                      controller: controller,
                      api: api,
                      prefs: prefs,
                      linkSource: SilentLinkSource(),
                      nativeIos: nativeIos,
                      nativeAndroid: nativeAndroid,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          Future<void> bringAppSwitcherIntoView() async {
            final statsScrollable = find
                .descendant(
                  of: find.byType(StatsScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
            await tester.dragUntilVisible(
              find.byType(AppSwitcher),
              statsScrollable,
              const Offset(0, -300),
            );
            await tester.drag(statsScrollable, const Offset(0, -160));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('app_switcher_recall')).hitTestable(),
              findsOneWidget,
            );
          }

          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(() => debugDefaultTargetPlatformOverride = null);

          if (!appleMobile) {
            await pumpShell(
              size: const Size(411, 914),
              nativeIos: false,
              nativeAndroid: true,
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 24),
            );
            if (await captureVisual(tester, 'android-study-question')) return;
            await tester.tap(find.text('Show answer'));
            await tester.pumpAndSettle();
            if (await captureVisual(tester, 'android-study-answer')) return;

            await tester.tap(find.text('Decks').last);
            await tester.pumpAndSettle();
            if (await captureVisual(tester, 'android-decks')) return;
            await tester.tap(find.text('Stats').last);
            await tester.pumpAndSettle();
            if (await captureVisual(tester, 'android-stats')) return;
            if (AppSwitcher.isSupported) {
              await bringAppSwitcherIntoView();
              if (await captureVisual(tester, 'android-app-switcher')) return;
            }
            await tester.tap(find.text('Read').last);
            await tester.pumpAndSettle();
            if (await captureVisual(tester, 'android-read')) return;
          }
          if (appleMobile) {
            await pumpShell(
              size: const Size(402, 874),
              nativeIos: true,
              nativeAndroid: false,
              padding: const EdgeInsets.fromLTRB(0, 59, 0, 34),
            );
            if (await captureVisual(tester, 'ios-study-answer')) return;
            await tester.tap(find.text('Stats').last);
            await tester.pumpAndSettle();
            if (AppSwitcher.isSupported) {
              await bringAppSwitcherIntoView();
              if (await captureVisual(tester, 'ios-app-switcher')) return;
            }
          }
          if (!appleMobile) {
            await pumpShell(
              size: const Size(900, 600),
              nativeIos: false,
              nativeAndroid: true,
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 24),
            );
            expect(find.byType(NavigationRail), findsOneWidget);
            if (await captureVisual(tester, 'android-wide-rail')) return;

            await pumpShell(
              size: const Size(320, 640),
              nativeIos: false,
              nativeAndroid: true,
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 24),
              textScaler: const TextScaler.linear(2),
            );
            expect(tester.takeException(), isNull);
            if (await captureVisual(tester, 'android-large-text')) return;
            await tester.ensureVisible(find.text('Good'));
            await tester.pumpAndSettle();
            expect(find.text('Good').hitTestable(), findsOneWidget);
          }
          if (appleMobile) {
            tester.view.physicalSize = const Size(402, 874);
            tester.view.devicePixelRatio = 1;
            debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

            await tester.pumpWidget(
              MaterialApp(
                theme: buildRecallTheme(),
                home: RepaintBoundary(
                  key: const Key('visual_benchmark_boundary'),
                  child: MediaQuery(
                    data: const MediaQueryData(
                      size: Size(402, 874),
                      padding: EdgeInsets.fromLTRB(0, 59, 0, 34),
                    ),
                    child: SettingsScreen(
                      prefs: prefs,
                      controller: controller,
                      nativeIos: true,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await captureVisual(tester, 'ios-settings');
            debugDefaultTargetPlatformOverride = null;
          }
          // Flutter verifies debug overrides before addTearDown callbacks run.
          debugDefaultTargetPlatformOverride = null;
        },
        tags: appleMobile ? const ['apple-mobile'] : const [],
      );
    }
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/core/widgets/recall_surfaces.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/desktop_reading_pane.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/remediation_rows.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart'
    show FakeRecallApi, captureVisual, loadVisualFonts;

final _now = DateTime(2026, 10, 25, 12);

class _Api extends FakeRecallApi {
  _Api({required int todayCount, int rereadCount = 0}) : super([]) {
    conceptPages = [
      for (var i = 0; i < rereadCount; i++) _page('reread-$i'),
      for (var i = 0; i < todayCount; i++) _page('today-$i'),
    ];
    conceptNodes = [
      for (final page in conceptPages)
        ConceptNodeInfo(
          nodeId: page.nodeId,
          title: page.title,
          module: 'Synthetic module',
        ),
    ];
    noteTags = {
      for (var i = 0; i < todayCount; i++) 'note-$i': 'node::today-$i',
    };
    // Alphabetical/page order is oldest first. All timestamps share a day,
    // so sorting only by day cannot satisfy the newest-first contract.
    reviewLog = [
      for (var i = 0; i < todayCount; i++)
        ReviewLogEntry(
          guid: 'note-$i',
          at: _now.subtract(Duration(minutes: todayCount - i)),
          rating: 3,
        ),
    ];
  }

  Completer<List<ConceptPage>>? pendingPages;

  @override
  Future<List<ConceptPage>> fetchConceptPages() =>
      pendingPages?.future ?? super.fetchConceptPages();
}

ConceptPage _page(String id) => ConceptPage(
  nodeId: id,
  title: 'Synthetic $id primer',
  bodyHtml: '<p>Invented reading fixture.</p>',
  updatedAt: _now,
);

class _Store extends LocalReviewStore {
  @override
  Future<List<LocalRemediationItem>> remediationQueue({DateTime? now}) =>
      super.remediationQueue(now: now ?? _now);
}

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  ReviewState get state => const ReviewState(loading: false);

  @override
  int get remediationRevision => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_Store> _show(
  WidgetTester tester,
  _Api api, {
  required bool companion,
  List<String> rereadIds = const [],
  bool settle = true,
}) async {
  final store = _Store();
  await store.enqueueRemediation(rereadIds, now: _now);
  tester.view.physicalSize = companion
      ? const Size(1280, 900)
      : const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = _Controller();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      home: RepaintBoundary(
        key: const Key('visual_benchmark_boundary'),
        child: Scaffold(
          body: companion
              ? Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 440,
                    child: DesktopReadingPane(
                      controller: controller,
                      api: api,
                      store: store,
                      clock: () => _now,
                    ),
                  ),
                )
              : ReadScreen(api: api, store: store, clock: () => _now),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return store;
}

void _expectRows(
  WidgetTester tester, {
  List<String> reread = const [],
  List<String> today = const [],
}) {
  final section = find.byKey(const Key('recall_read_today_hero'));
  final rereadRows = find.descendant(
    of: section,
    matching: find.byType(RereadRow),
  );
  final todayRows = find.descendant(
    of: section,
    matching: find.byType(PrimerRow),
  );
  expect(
    tester.widgetList<RereadRow>(rereadRows).map((row) => row.page.nodeId),
    reread,
  );
  expect(
    tester.widgetList<PrimerRow>(todayRows).map((row) => row.page.nodeId),
    today,
  );
  final keys = [
    for (final id in reread) Key('recall_reread_row_$id'),
    for (final id in today) Key('recall_primer_row_$id'),
  ];
  for (var i = 1; i < keys.length; i++) {
    expect(
      tester.getTopLeft(find.byKey(keys[i - 1])).dy,
      lessThan(tester.getTopLeft(find.byKey(keys[i])).dy),
    );
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() async {
    await loadVisualFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    // Deterministic stand-in for the system sans font in widget captures.
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Medium.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Bold.ttf')))
        .load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final companion in [false, true]) {
    final surface = companion ? 'desktop companion' : 'Read tab';

    testWidgets('$surface shows only the five newest of eight recent pages', (
      tester,
    ) async {
      await _show(tester, _Api(todayCount: 8), companion: companion);
      _expectRows(
        tester,
        today: ['today-7', 'today-6', 'today-5', 'today-4', 'today-3'],
      );
      for (var i = 0; i < 3; i++) {
        expect(find.text('Synthetic today-$i primer'), findsNothing);
      }
      await captureVisual(
        tester,
        companion ? 'recent-cap-companion' : 'recent-cap-phone',
      );
    });

    testWidgets('$surface keeps two rereads before the three newest pages', (
      tester,
    ) async {
      final store = await _show(
        tester,
        _Api(todayCount: 6, rereadCount: 2),
        companion: companion,
        rereadIds: ['reread-1', 'reread-0'],
      );
      _expectRows(
        tester,
        reread: ['reread-1', 'reread-0'],
        today: ['today-5', 'today-4', 'today-3'],
      );
      expect((await store.remediationQueue()).map((item) => item.nodeId), [
        'reread-1',
        'reread-0',
      ]);
      await captureVisual(
        tester,
        companion ? 'recent-cap-mixed-companion' : 'recent-cap-mixed-phone',
      );
    });

    testWidgets('$surface orders by the latest eligible review of each page', (
      tester,
    ) async {
      final api = _Api(todayCount: 8);
      api.reviewLog.insert(
        0,
        ReviewLogEntry(guid: 'note-0', at: _now, rating: 3),
      );
      api.reviewLog.add(
        ReviewLogEntry(
          guid: 'note-1',
          at: _now.add(const Duration(days: 1)),
          rating: 3,
        ),
      );
      await _show(tester, api, companion: companion);
      _expectRows(
        tester,
        today: ['today-0', 'today-7', 'today-6', 'today-5', 'today-4'],
      );
    });

    testWidgets('$surface keeps three queued rereads and two newest pages', (
      tester,
    ) async {
      final ids = [for (var i = 0; i < 3; i++) 'reread-$i'];
      final store = await _show(
        tester,
        _Api(todayCount: 4, rereadCount: 3),
        companion: companion,
        rereadIds: ids,
      );
      _expectRows(tester, reread: ids, today: ['today-3', 'today-2']);
      expect((await store.remediationQueue()).map((item) => item.nodeId), ids);
    });

    testWidgets('$surface shows all three pages newest first', (tester) async {
      await _show(tester, _Api(todayCount: 3), companion: companion);
      _expectRows(tester, today: ['today-2', 'today-1', 'today-0']);
    });

    testWidgets('$surface keeps the existing empty message', (tester) async {
      await _show(tester, _Api(todayCount: 0), companion: companion);
      _expectRows(tester);
      expect(find.text('No recent reading yet.'), findsOneWidget);
    });

    testWidgets('$surface keeps three loading skeleton rows', (tester) async {
      final pending = Completer<List<ConceptPage>>();
      await _show(
        tester,
        _Api(todayCount: 8)..pendingPages = pending,
        companion: companion,
        settle: false,
      );
      final skeletons = tester.widget<RecallListGroup>(
        find.byKey(const Key('recall_read_skeleton_rows')),
      );
      expect(skeletons.children, hasLength(3));
      pending.complete([]);
      await tester.pumpAndSettle();
    });
  }
}

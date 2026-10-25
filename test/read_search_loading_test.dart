import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart' show FakeRecallApi;

final _now = DateTime(2026, 10, 24, 12);
final _pages = [
  for (final id in ['related', 'recent', 'chat-fixture', 'unreviewed'])
    ConceptPage(
      nodeId: id,
      title: 'Synthetic $id primer',
      bodyHtml: '<p>Synthetic reading fixture.</p>',
      updatedAt: _now,
    ),
];

class _ReadApi extends FakeRecallApi {
  _ReadApi() : super([]) {
    conceptPages = _pages;
    conceptNodes = [
      for (final page in _pages)
        ConceptNodeInfo(
          nodeId: page.nodeId,
          title: page.title,
          module: 'Synthetic module',
        ),
    ];
    noteTags = {'synthetic-note': 'node::recent'};
    reviewLog = [ReviewLogEntry(guid: 'synthetic-note', at: _now, rating: 3)];
  }

  Completer<List<ConceptPage>>? pending;

  @override
  Future<List<ConceptPage>> fetchConceptPages() =>
      pending?.future ?? super.fetchConceptPages();
}

final _search = find.byKey(const Key('recall_primer_search'));

Future<void> _show(
  WidgetTester tester,
  ReadScreen screen,
  Size size, {
  double scale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRecallTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(body: screen),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    testWidgets('full Read library is search-only at $size', (tester) async {
      ConceptPage? opened;
      await _show(
        tester,
        ReadScreen(
          api: _ReadApi(),
          relatedNodeIds: const ['related'],
          clock: () => _now,
          onOpenPrimer: (page, _) async => opened = page,
        ),
        size,
      );

      void expectContextSections() {
        for (final title in [
          'For this card',
          'From your chats',
          'Recent reading',
        ]) {
          expect(find.text(title), findsOneWidget);
        }
        for (final page in _pages.take(3)) {
          expect(find.text(page.title), findsOneWidget);
        }
        expect(find.text(_pages.last.title), findsNothing);
        expect(find.text('More from the library'), findsNothing);
        expect(
          find.text('All available primers are shown above.'),
          findsNothing,
        );
      }

      expectContextSections();
      await tester.ensureVisible(_search);
      await tester.enterText(_search, 'unreviewed');
      await tester.pumpAndSettle();
      expect(find.byType(PrimerRow), findsOneWidget);
      expect(find.text(_pages.last.title), findsOneWidget);
      expect(find.text('Recent reading'), findsNothing);
      await tester.tap(find.text(_pages.last.title));
      expect(opened, same(_pages.last));

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expectContextSections();
      await tester.enterText(_search, '   ');
      await tester.pumpAndSettle();
      expectContextSections();

      await tester.enterText(_search, 'no matching synthetic concept');
      await tester.pumpAndSettle();
      expect(find.text('No primers match your search.'), findsOneWidget);
      expect(find.byType(PrimerRow), findsNothing);
      await tester.enterText(_search, '');
      await tester.pumpAndSettle();
      expectContextSections();
      expect(tester.takeException(), isNull);
    });

    for (final libraryFirst in [false, true]) {
      testWidgets(
        'Read skeleton matches final layout at $size, libraryFirst=$libraryFirst',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final pending = Completer<List<ConceptPage>>();
            final api = _ReadApi()
              ..pending = pending
              ..reviewLog = []
              ..conceptPages = [_pages[1]];
            await _show(
              tester,
              ReadScreen(
                api: api,
                libraryFirst: libraryFirst,
                showHeader: !libraryFirst,
                clock: () => _now,
              ),
              size,
              scale: 2,
              settle: false,
            );

            expect(find.byKey(const ValueKey('read_loading')), findsOneWidget);
            expect(
              find.byKey(const Key('recall_read_skeleton_rows')),
              findsOneWidget,
            );
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.text('Loading primers…'), findsNothing);
            expect(find.bySemanticsLabel('Loading primers'), findsOneWidget);
            expect(
              find.text('Read'),
              libraryFirst ? findsNothing : findsOneWidget,
            );
            final libraryPosition = tester.getTopLeft(find.text('Library'));
            final recentPosition = tester.getTopLeft(
              find.text('Recent reading'),
            );
            final searchPosition = tester.getTopLeft(_search);
            expect(libraryPosition.dx, UiSpacing.md);
            expect(recentPosition.dx, UiSpacing.md);
            expect(searchPosition.dx, UiSpacing.md);
            expect(tester.widget<TextField>(_search).enabled, isFalse);

            pending.complete([_pages[1]]);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('recall_read_skeleton_rows')),
              findsNothing,
            );
            expect(find.bySemanticsLabel('Loading primers'), findsNothing);
            expect(
              tester.getTopLeft(find.text('Recent reading')),
              recentPosition,
            );
            // The library-first companion keeps its search at the same position.
            // The full Read library follows a variable number of recent rows.
            if (libraryFirst) {
              expect(tester.getTopLeft(find.text('Library')), libraryPosition);
              expect(tester.getTopLeft(_search), searchPosition);
            }
            expect(tester.widget<TextField>(_search).enabled, isNot(isFalse));
            expect(find.text(_pages[1].title), findsNothing);
            expect(
              find.text('All available primers are shown above.'),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}

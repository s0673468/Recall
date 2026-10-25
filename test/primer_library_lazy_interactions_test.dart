import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

final _pages = List.generate(
  500,
  (id) => ConceptPage(
    nodeId: 'synthetic-$id',
    title:
        'Synthetic primer ${id.toString().padLeft(3, '0')} with an invented longer title',
    bodyHtml: '',
    updatedAt: DateTime.utc(2026, 10, 15),
  ),
);
final _nodes = [
  for (var id = 0; id < _pages.length; id++)
    ConceptNodeInfo(
      nodeId: _pages[id].nodeId,
      title: _pages[id].title,
      module: 'Synthetic module ${id ~/ 100}',
    ),
];

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpLibrary(
  WidgetTester tester, {
  double textScale = 1,
  ValueChanged<ConceptPage>? onOpen,
  bool renderPreview = false,
}) async {
  final baseTheme = buildRecallTheme();
  var theme = baseTheme;
  if (renderPreview) {
    // A shipped technical font makes a readable deterministic widget preview.
    // It is a system-font surrogate, not physical Android typography proof.
    final font = FontLoader('SyntheticPrimerPreview')
      ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'));
    await font.load();
    theme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(
        fontFamily: 'SyntheticPrimerPreview',
      ),
      appBarTheme: baseTheme.appBarTheme.copyWith(
        titleTextStyle: baseTheme.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: 'SyntheticPrimerPreview',
        ),
      ),
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        hintStyle: baseTheme.inputDecorationTheme.hintStyle?.copyWith(
          fontFamily: 'SyntheticPrimerPreview',
        ),
      ),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: const Key('synthetic_primer_preview'),
        child: Banner(
          message: 'SYNTHETIC PREVIEW',
          location: BannerLocation.topEnd,
          child: PrimerLibraryScreen(
            pages: _pages,
            conceptNodes: _nodes,
            onOpenPrimer: onOpen ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'title and module search retain last primer identity through lazy scrolling',
    (tester) async {
      _phone(tester);
      final selected = <ConceptPage>[];
      await _pumpLibrary(tester, onOpen: selected.add);
      final search = find.byKey(const Key('recall_primer_search'));
      final last = find.byKey(
        const ValueKey('recall_primer_row_synthetic-499'),
      );

      await tester.enterText(search, 'Synthetic primer 499');
      await tester.pumpAndSettle();
      expect(find.byType(PrimerRow), findsOneWidget);
      await tester.tap(last);
      expect(selected.single, same(_pages.last));

      await tester.enterText(search, 'no synthetic match');
      await tester.pumpAndSettle();
      expect(find.text('No primers match your search.'), findsOneWidget);
      expect(find.byType(PrimerRow), findsNothing);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recall_primer_row_synthetic-0')),
        findsOneWidget,
      );
      expect(find.byType(PrimerRow).evaluate().length, inInclusiveRange(1, 39));

      await tester.enterText(search, 'Synthetic module 4');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recall_primer_row_synthetic-400')),
        findsOneWidget,
      );
      expect(last, findsNothing);
      expect(find.byType(PrimerRow).evaluate().length, inInclusiveRange(1, 39));
      await tester.scrollUntilVisible(
        last,
        500,
        scrollable: find
            .descendant(
              of: find.byType(PrimerLibraryScreen),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 80,
      );
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      expect(selected.length, 2);
      expect(selected.last, same(_pages.last));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'companion library only shows search results including excluded concepts',
    (tester) async {
      _phone(tester);
      final selected = <ConceptPage>[];
      final queries = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PrimerLibraryContent(
                pages: _pages.take(3).toList(),
                conceptNodes: _nodes.take(3).toList(),
                browseExcludedNodeIds: const {'synthetic-2'},
                collapsedBrowse: true,
                onOpenPrimer: selected.add,
                onQueryChanged: queries.add,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(PrimerRow), findsNothing);
      expect(
        find.byKey(const Key('recall_primer_browse_toggle')),
        findsNothing,
      );
      expect(find.text('Browse library'), findsNothing);
      expect(find.text('Hide library'), findsNothing);
      expect(
        find.byKey(const ValueKey('recall_primer_row_synthetic-2')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'Synthetic primer 002',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recall_primer_row_synthetic-2')),
      );
      expect(selected.single, same(_pages[2]));
      expect(queries.last, 'Synthetic primer 002');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.byType(PrimerRow), findsNothing);
      expect(queries.last, isEmpty);
      final search = find.byKey(const Key('recall_primer_search'));
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
      await tester.enterText(search, 'unmatched synthetic query');
      await tester.pumpAndSettle();
      expect(find.text('No primers match your search.'), findsOneWidget);
      expect(find.byType(PrimerRow), findsNothing);
      await tester.enterText(search, '   ');
      await tester.pumpAndSettle();
      expect(find.text('No primers match your search.'), findsNothing);
      expect(find.byType(PrimerRow), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final pages in [<ConceptPage>[], _pages.take(3).toList()]) {
    testWidgets(
      'idle companion has no list or empty message (${pages.length})',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildRecallTheme(),
            home: Scaffold(
              body: PrimerLibraryContent(
                pages: pages,
                conceptNodes: _nodes,
                browseExcludedNodeIds: {for (final page in pages) page.nodeId},
                collapsedBrowse: true,
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('recall_primer_search')), findsOneWidget);
        expect(find.byType(PrimerRow), findsNothing);
        expect(
          find.byKey(const Key('recall_primer_browse_toggle')),
          findsNothing,
        );
        for (final message in [
          'No primers match your search.',
          'No primers available.',
          'All available primers are in your reading list.',
          'All available primers are shown above.',
        ]) {
          expect(find.text(message), findsNothing);
        }
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('synthetic 390px library preview at text scale $scale', (
      tester,
    ) async {
      _phone(tester);
      await _pumpLibrary(tester, textScale: scale, renderPreview: true);
      expect(find.text('Concept primers'), findsOneWidget);
      expect(find.byKey(const Key('recall_primer_search')), findsOneWidget);
      expect(find.byType(PrimerRow).evaluate().length, inInclusiveRange(1, 39));
      expect(tester.takeException(), isNull);
      final output = Platform.environment['RECALL_PRIMER_VISUAL_OUTPUT'];
      if (output != null && output.isNotEmpty) {
        await expectLater(
          find.byKey(const Key('synthetic_primer_preview')),
          matchesGoldenFile(
            Uri.file(
              '$output/primer-library-${scale == 1 ? 'normal' : 'large'}-390.png',
            ),
          ),
        );
      }
    });
  }
}

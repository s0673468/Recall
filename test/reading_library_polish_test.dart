import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/desktop_reading_pane.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

// Closed in-memory fixtures: no account, storage, HTTP client or card data.
final _now = DateTime.utc(2026, 10, 24, 12);
final _pages = List.generate(
  40,
  (i) => ConceptPage(
    nodeId: 'fixture-$i',
    title:
        'Synthetic concept ${i.toString().padLeft(2, '0')} with a long title',
    bodyHtml: List.generate(35, (p) => '<p>Synthetic paragraph $p.</p>').join(),
    updatedAt: _now,
  ),
);
final _nodes = [
  for (final page in _pages)
    ConceptNodeInfo(
      nodeId: page.nodeId,
      title: page.title,
      module: 'Fixture module',
    ),
];

class _Api implements RecallApi {
  bool fail = false;
  Completer<List<ConceptPage>>? pending;
  List<ConceptPage> pages = _pages;

  @override
  Future<List<ConceptPage>> fetchConceptPages() async {
    if (fail) throw StateError('Synthetic unavailable fixture');
    return pending?.future ?? pages;
  }

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => _nodes;
  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async => [];
  @override
  Future<Map<String, String>> fetchNoteTags() async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API access');
}

class _Store extends LocalReviewStore {
  @override
  Future<List<LocalRemediationItem>> remediationQueue({DateTime? now}) async =>
      [];
}

class _Controller extends ChangeNotifier implements ReviewController {
  @override
  final engine = FsrsEngine();
  @override
  final state = const ReviewState(
    loading: false,
    decks: [
      DeckRow(deckId: 1, name: 'Synthetic curriculum::A very long deck name'),
    ],
  );
  @override
  int get remediationRevision => 0;
  @override
  Null get currentUser => null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected controller access');
}

class _Prefs extends ChangeNotifier implements RecallPrefsController {
  @override
  RecallPrefs value = const RecallPrefs();
  @override
  Future<void> update(RecallPrefs next) async {
    value = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected preference access');
}

final _search = find.byKey(const Key('recall_primer_search'));

Future<void> _show(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(390, 844),
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
      home: screen,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

ScrollableState _scroll(WidgetTester tester, Finder parent) =>
    tester.state<ScrollableState>(
      find.descendant(of: parent, matching: find.byType(Scrollable)).first,
    );

void main() {
  testWidgets(
    'whitespace search remains clearable and clear returns typing focus',
    (tester) async {
      await _show(
        tester,
        PrimerLibraryScreen(pages: _pages, conceptNodes: _nodes),
      );
      await tester.enterText(_search, '   ');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Clear search'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.enterText(_search, 'no match');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
    },
  );

  testWidgets(
    'a primer reopens at its position while another starts at the top',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await _show(
        tester,
        Scaffold(
          body: DesktopReadingPane(
            controller: controller,
            api: _Api(),
            store: _Store(),
            clock: () => _now,
          ),
        ),
      );
      Future<void> open(int i) async {
        await tester.enterText(_search, _pages[i].title);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('recall_primer_row_${_pages[i].nodeId}')),
        );
        await tester.pumpAndSettle();
      }

      Future<void> back() async {
        await tester.tap(find.byTooltip('Back to reading'));
        await tester.pumpAndSettle();
      }

      await open(0);
      _scroll(tester, find.byType(PrimerContent)).position.jumpTo(420);
      await tester.pumpAndSettle();
      await back();
      await open(1);
      expect(_scroll(tester, find.byType(PrimerContent)).position.pixels, 0);
      _scroll(tester, find.byType(PrimerContent)).position.jumpTo(180);
      await tester.pumpAndSettle();
      await back();
      await open(0);
      expect(_scroll(tester, find.byType(PrimerContent)).position.pixels, 420);
      await back();
      await open(1);
      expect(_scroll(tester, find.byType(PrimerContent)).position.pixels, 180);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reading error retry restores the query and matching layout', (
    tester,
  ) async {
    final api = _Api();
    final key = GlobalKey<ReadScreenState>();
    await _show(
      tester,
      Scaffold(
        body: ReadScreen(
          key: key,
          api: api,
          store: _Store(),
          clock: () => _now,
        ),
      ),
    );
    await tester.ensureVisible(_search);
    await tester.enterText(_search, _pages[3].title);
    await tester.pumpAndSettle();
    api.fail = true;
    unawaited(key.currentState!.reload(refresh: true));
    await tester.pumpAndSettle();
    expect(find.text('Could not load reading'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.byKey(const Key('recall_read_retry')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_search).controller!.text, _pages[3].title);
    expect(find.byType(PrimerRow), findsOneWidget);
    expect(find.text('Recent reading'), findsNothing);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Recent reading'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading header fits narrow panes with double text', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await _show(
      tester,
      Scaffold(
        body: DesktopReadingPane(
          controller: controller,
          api: _Api()..pages = [_pages[0]],
          store: _Store(),
          clock: () => _now,
        ),
      ),
      size: const Size(280, 800),
      scale: 2,
    );
    await tester.tap(find.byKey(const Key('recall_primer_browse_toggle')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(_pages[0].title));
    await tester.tap(find.text(_pages[0].title));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to reading'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings slider and per-deck actions announce their purpose', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final prefs = _Prefs();
      final controller = _Controller();
      addTearDown(prefs.dispose);
      addTearDown(controller.dispose);
      await _show(tester, SettingsScreen(prefs: prefs, controller: controller));
      final slider = find.semantics.byPredicate(
        (node) => node.getSemanticsData().flagsCollection.isSlider,
      );
      expect(
        slider.evaluate().single.getSemanticsData().label,
        'Desired retention: 90%',
      );
      await tester.ensureVisible(find.text('Per-deck new-card limits'));
      await tester.tap(find.text('Per-deck new-card limits'));
      await tester.pumpAndSettle();
      const name = 'Synthetic curriculum  ›  A very long deck name';
      await tester.ensureVisible(find.text('Set override'));
      expect(
        find.bySemanticsLabel('Set new-card limit for $name'),
        findsOneWidget,
      );
      await tester.tap(find.text('Set override'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use default'));
      expect(
        find.bySemanticsLabel('Use default new-card limit for $name'),
        findsOneWidget,
      );
      await tester.tap(find.text('Use default'));
      await tester.pumpAndSettle();
      expect(prefs.value.perDeck, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  for (final size in const [Size(320, 740), Size(1280, 800)]) {
    testWidgets(
      'synthetic dark library supports long titles, empty results and keyboard at $size',
      (tester) async {
        ConceptPage? opened;
        await _show(
          tester,
          PrimerLibraryScreen(
            pages: _pages,
            conceptNodes: _nodes,
            onOpenPrimer: (page) => opened = page,
          ),
          size: size,
          scale: 2,
        );
        expect(Theme.of(tester.element(_search)).brightness, Brightness.dark);
        await tester.enterText(_search, _pages[0].title);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(opened, same(_pages[0]));
        await tester.enterText(_search, 'unmatched synthetic query');
        await tester.pumpAndSettle();
        expect(find.text('No primers match your search.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reading loading and empty states stay usable at double text', (
    tester,
  ) async {
    final pending = Completer<List<ConceptPage>>();
    await _show(
      tester,
      Scaffold(
        body: ReadScreen(
          api: _Api()..pending = pending,
          store: _Store(),
          clock: () => _now,
        ),
      ),
      size: const Size(320, 740),
      scale: 2,
      settle: false,
    );
    expect(find.text('Loading primers…'), findsOneWidget);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No recent reading yet.'), findsOneWidget);
    expect(find.text('No primers available.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

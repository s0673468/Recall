import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/widgets/concept_retention_panel.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/list_feedback_fixture.dart';

// Closed synthetic fixtures, shared by VM and Chrome. No storage or network.
final _now = DateTime(2026, 10, 24, 12);
final _pages = [
  for (final id in [
    'liked',
    'disliked',
    'mixed',
    'neutral',
    'reread',
    'chat-fixture',
  ])
    ConceptPage(
      nodeId: id,
      title: 'Synthetic $id primer with a longer title',
      bodyHtml: '',
      updatedAt: _now,
    ),
];
final _nodes = [
  for (final page in _pages)
    ConceptNodeInfo(
      nodeId: page.nodeId,
      title: page.title,
      module: 'Synthetic module',
    ),
];

class _Api extends ListFeedbackFixtureApi {
  _Api()
    : super(
        initialFlags: [
          for (final id in ['liked', 'mixed', 'reread', 'chat-fixture'])
            {'guid': 'synthetic-$id', 'reason': 'like'},
          for (final id in ['disliked', 'mixed'])
            {'guid': 'synthetic-$id', 'reason': 'dislike'},
        ],
      );
  int tagReads = 0;

  @override
  Future<List<ConceptPage>> fetchConceptPages() async => _pages;
  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => _nodes;
  @override
  Future<Map<String, String>> fetchNoteTags() async {
    tagReads++;
    return {
      for (final page in _pages)
        'synthetic-${page.nodeId}': 'node::${page.nodeId}',
    };
  }

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async => [
    for (final id in ['liked', 'disliked', 'mixed', 'neutral'])
      ReviewLogEntry(guid: 'synthetic-$id', at: _now, rating: 3),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API access');
}

class _Store extends LocalReviewStore {
  @override
  Future<List<LocalRemediationItem>> remediationQueue({DateTime? now}) async =>
      [LocalRemediationItem(nodeId: 'reread', queuedAt: _now)];

  @override
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) async =>
      [];
  @override
  Future<List<Map<String, dynamic>>> likedFlags({String? ownerScope}) async =>
      [];
}

class _HoldingStore extends _Store {
  final pending = Completer<List<Map<String, dynamic>>>();
  bool hold = true;

  @override
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) =>
      hold ? pending.future : super.flagOutbox(ownerScope: ownerScope);
}

Future<_Api> _api(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final api = _Api();
      // Supabase starts a JSON isolate. Initialize it on the real event loop,
      // outside the widget fake clock, so its teardown can finish.
      api.client;
      return api;
    }))!;

Future<void> _show(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(390, 844),
  double scale = 1,
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
      home: RepaintBoundary(key: const Key('synthetic_lists'), child: screen),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(String id) => find.byKey(ValueKey('recall_primer_row_$id'));

Future<void> _expectFeedback(
  WidgetTester tester,
  Finder row, {
  bool liked = false,
  bool disliked = false,
}) async {
  final semantics = tester.ensureSemantics();
  try {
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    for (final status in [
      (icon: Icons.thumb_up_outlined, label: 'Has liked cards', present: liked),
      (
        icon: Icons.thumb_down_outlined,
        label: 'Has disliked cards',
        present: disliked,
      ),
    ]) {
      expect(
        find.descendant(of: row, matching: find.byIcon(status.icon)),
        status.present ? findsOneWidget : findsNothing,
      );
      if (status.present) {
        expect(find.bySemanticsLabel(RegExp(status.label)), findsWidgets);
      }
    }
    expect(tester.takeException(), isNull);
  } finally {
    semantics.dispose();
  }
}

Future<void> _refreshFeedback(
  WidgetTester tester,
  GlobalKey<ReadScreenState> key,
  _Api api,
) async {
  final started = Completer<void>();
  api.beforeRead = () async {
    if (!started.isCompleted) started.complete();
  };
  await key.currentState!.reload(refresh: true);
  await tester.pump();
  await tester.runAsync(
    () => started.future.timeout(const Duration(seconds: 5)),
  );
  await tester.pumpAndSettle();
  api.beforeRead = null;
}

void main() {
  setUpAll(() async {
    // Browser tests use the engine's test fonts; font loading is VM preview
    // preparation and can wait on an unpumped browser frame during setUpAll.
    if (kIsWeb) return;
    await (FontLoader(
            // Bundled surrogate for the system font in deterministic widget previews.
            'Roboto',
          )
          ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Medium.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DMSans-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'standalone primer library maps flags once and preserves search and navigation',
    (tester) async {
      final api = await _api(tester);
      ConceptPage? opened;
      await _show(
        tester,
        PrimerLibraryScreen(
          pages: _pages,
          conceptNodes: _nodes,
          api: api,
          store: _Store(),
          onOpenPrimer: (page) => opened = page,
        ),
      );
      await _expectFeedback(tester, _row('liked'), liked: true);
      await _expectFeedback(tester, _row('disliked'), disliked: true);
      await _expectFeedback(tester, _row('mixed'), liked: true, disliked: true);
      await _expectFeedback(tester, _row('neutral'));
      await tester.ensureVisible(find.byKey(const Key('recall_primer_search')));
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'Synthetic mixed',
      );
      await tester.pumpAndSettle();
      expect(find.byType(PrimerRow), findsOneWidget);
      await _expectFeedback(tester, _row('mixed'), liked: true, disliked: true);
      await tester.tap(_row('mixed'));
      expect(opened!.nodeId, 'mixed');
      expect(api.flagReads, 1);
      expect(api.tagReads, 1);
    },
  );

  testWidgets('reading, related, chat and reread rows expose mapped feedback', (
    tester,
  ) async {
    final api = await _api(tester);
    await _show(
      tester,
      Scaffold(
        body: ReadScreen(
          api: api,
          store: _Store(),
          relatedNodeIds: const ['liked'],
          clock: () => _now,
        ),
      ),
      size: const Size(1280, 2200),
    );
    await _expectFeedback(
      tester,
      find.descendant(
        of: find.byKey(const Key('recall_read_related')),
        matching: _row('liked'),
      ),
      liked: true,
    );
    await _expectFeedback(tester, _row('disliked'), disliked: true);
    await _expectFeedback(tester, _row('mixed'), liked: true, disliked: true);
    await _expectFeedback(tester, _row('neutral'));
    await _expectFeedback(tester, _row('chat-fixture'), liked: true);
    await _expectFeedback(
      tester,
      find.byKey(const ValueKey('recall_reread_row_reread')),
      liked: true,
    );
    expect(api.flagReads, 1);
  });

  testWidgets(
    'embedded library search reuses feedback and refresh replaces it',
    (tester) async {
      final api = await _api(tester);
      final key = GlobalKey<ReadScreenState>();
      await _show(
        tester,
        Scaffold(
          body: ReadScreen(
            key: key,
            api: api,
            store: _Store(),
            libraryFirst: true,
            clock: () => _now,
          ),
        ),
      );
      final search = find.byKey(const Key('recall_primer_search'));
      await tester.enterText(search, 'Synthetic mixed');
      await tester.pumpAndSettle();
      await _expectFeedback(tester, _row('mixed'), liked: true, disliked: true);
      expect(api.flagReads, 1);
      api.flags = [
        {'guid': 'synthetic-mixed', 'reason': 'dislike'},
      ];
      await _refreshFeedback(tester, key, api);
      await _expectFeedback(tester, _row('mixed'), disliked: true);
      expect(api.flagReads, 2);
      expect(
        tester.widget<TextField>(search).controller!.text,
        'Synthetic mixed',
      );
    },
  );

  testWidgets('Stats library route receives the feedback source', (
    tester,
  ) async {
    final api = await _api(tester);
    final store = _Store();
    var storeRequests = 0;
    await _show(
      tester,
      Scaffold(
        body: ConceptRetentionPanel(
          ranked: const [],
          notEnoughData: 0,
          coveredNodeCount: 0,
          totalConcepts: _nodes.length,
          conceptPages: _pages,
          conceptNodes: _nodes,
          api: api,
          libraryStore: () {
            storeRequests++;
            return store;
          },
        ),
      ),
    );
    expect(storeRequests, 0);
    await tester.tap(find.text('Browse concept primers'));
    await tester.pumpAndSettle();
    await _expectFeedback(tester, _row('mixed'), liked: true, disliked: true);
    expect(api.flagReads, 1);
    expect(storeRequests, 1);
  });

  testWidgets(
    'slow feedback leaves reading usable and an older load cannot replace refresh',
    (tester) async {
      final api = await _api(tester);
      final store = _HoldingStore();
      final key = GlobalKey<ReadScreenState>();
      await _show(
        tester,
        Scaffold(
          body: ReadScreen(key: key, api: api, store: store, clock: () => _now),
        ),
        size: const Size(1280, 2200),
      );
      await _expectFeedback(tester, _row('liked'));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      store.hold = false;
      api.flags = [];
      await _refreshFeedback(tester, key, api);
      store.pending.complete([
        {'guid': 'synthetic-liked', 'reason': 'like'},
      ]);
      await tester.pumpAndSettle();
      await _expectFeedback(tester, _row('liked'));
    },
  );

  testWidgets('unavailable feedback never hides library or reading rows', (
    tester,
  ) async {
    final api = await _api(tester)
      ..unavailable = true;
    await _show(
      tester,
      Scaffold(
        body: ReadScreen(api: api, store: _Store(), clock: () => _now),
      ),
      size: const Size(1280, 2200),
    );
    expect(_row('liked'), findsOneWidget);
    expect(_row('disliked'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    expect(find.byIcon(Icons.thumb_down_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(320, 740), Size(1280, 800)]) {
    testWidgets('feedback stays accessible at double text on $size', (
      tester,
    ) async {
      await _show(
        tester,
        PrimerLibraryScreen(
          pages: _pages,
          conceptNodes: _nodes,
          api: await _api(tester),
          store: _Store(),
        ),
        size: size,
        scale: 2,
      );
      await tester.enterText(
        find.byKey(const Key('recall_primer_search')),
        'Synthetic mixed',
      );
      await tester.pumpAndSettle();
      await _expectFeedback(tester, _row('mixed'), liked: true, disliked: true);
      if (const bool.fromEnvironment('RECALL_LIST_VISUAL')) {
        await expectLater(
          find.byKey(const Key('synthetic_lists')),
          matchesGoldenFile('../build/list-feedback-${size.width.toInt()}.png'),
        );
      }
    });
  }
}

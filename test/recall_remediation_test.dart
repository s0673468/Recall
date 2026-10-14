import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/remediation_service.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Local primer remediation', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('only a true lapse enqueues a tagged concept', () async {
      final card = testCard(
        id: 401,
        state: 2,
        reps: 3,
        due: DateTime.utc(2026, 7, 1),
        tags: 'node::m00-vector-geometry',
      );
      final api = FakeRecallApi([card]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.current?.tags, 'node::m00-vector-geometry');
      controller.flip();
      await controller.rate(Rating.again);

      expect((await store.outbox()).single['lapsed'], isTrue);
      await controller.syncPending();
      expect(api.applied, hasLength(1));
      expect(api.applied.single['lapsed'], isTrue);
      expect((await store.remediationQueue()).map((item) => item.nodeId), [
        'm00-vector-geometry',
      ]);
    });

    test('learning Again does not become a remediation lapse', () async {
      final api = FakeRecallApi([
        testCard(id: 402, state: 1, tags: 'node::m00-learning'),
        testCard(
          id: 403,
          state: 2,
          reps: 3,
          due: DateTime.utc(2026, 7, 1),
          tags: 'node::m00-review',
        ),
      ]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      controller.flip();
      await controller.rate(Rating.again);
      controller.flip();
      await controller.rate(Rating.again);
      await controller.syncPending();

      expect(api.applied[0]['rating'], Rating.again.value);
      expect(api.applied[0]['lapsed'], isFalse);
      expect(api.applied[1]['lapsed'], isTrue);
      expect((await store.remediationQueue()).map((item) => item.nodeId), [
        'm00-review',
      ]);
    });

    test('remediation is local and does not add a scheduling write', () async {
      final card = testCard(
        id: 404,
        state: 2,
        reps: 3,
        due: DateTime.utc(2026, 7, 1),
        tags: 'node::m00-vector-geometry',
      );
      final api = FakeRecallApi([card]);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      controller.flip();
      await controller.rate(Rating.again);
      await controller.syncPending();

      expect(api.applied, hasLength(1));
      expect(api.server.cards[card.id]!.lapses, 1);
      expect(await store.outbox(), isEmpty);
      expect(await store.remediationQueue(), hasLength(1));
    });

    test(
      'same-day remediation is capped, deduplicated, and survives restart',
      () async {
        final now = DateTime(2026, 8, 5, 12);
        final store = LocalReviewStore();
        await store.enqueueRemediation([
          'm00-a',
          'm00-b',
          'm00-a',
          'm00-c',
          'm00-d',
        ], now: now);

        final restarted = LocalReviewStore();
        expect(
          (await restarted.remediationQueue(
            now: now,
          )).map((item) => item.nodeId),
          ['m00-a', 'm00-b', 'm00-c'],
        );
        await restarted.enqueueRemediation(['m00-b', 'm00-d'], now: now);
        expect(
          (await restarted.remediationQueue(
            now: now,
          )).map((item) => item.nodeId),
          ['m00-a', 'm00-b', 'm00-c'],
        );

        expect(await restarted.completeRemediation('m00-b', now: now), isTrue);
        expect(
          (await restarted.remediationQueue(
            now: now,
          )).map((item) => item.nodeId),
          ['m00-a', 'm00-c'],
        );
      },
    );

    test('unresolved ids and primers read today are skipped', () {
      final queuedAt = DateTime(2026, 8, 5, 12);
      final pages = [
        ConceptPage(
          nodeId: 'm00-read',
          title: 'Already read',
          bodyHtml: 'Read',
          updatedAt: queuedAt,
        ),
        ConceptPage(
          nodeId: 'm00-unread',
          title: 'Needs reread',
          bodyHtml: 'Unread',
          updatedAt: queuedAt,
        ),
      ];
      final visible = visibleRemediationPages(
        queue: [
          LocalRemediationItem(nodeId: 'm00-read', queuedAt: queuedAt),
          LocalRemediationItem(nodeId: 'm99-missing', queuedAt: queuedAt),
          LocalRemediationItem(nodeId: 'm00-unread', queuedAt: queuedAt),
        ],
        conceptNodes: const [
          ConceptNodeInfo(nodeId: 'm00-read', title: 'Read', module: 'M00'),
          ConceptNodeInfo(nodeId: 'm00-unread', title: 'Unread', module: 'M00'),
        ],
        conceptPages: pages,
        readTodayPages: [pages.first],
      );

      expect(visible.map((page) => page.nodeId), ['m00-unread']);
    });

    testWidgets('done state renders and completes reread rows', (tester) async {
      final page = ConceptPage(
        nodeId: 'm00-vector-geometry',
        title: 'Vector geometry primer',
        bodyHtml: 'Projection',
        updatedAt: DateTime(2026, 8, 5),
      );
      final api = FakeRecallApi(const [])
        ..conceptNodes = const [
          ConceptNodeInfo(
            nodeId: 'm00-vector-geometry',
            title: 'Vector geometry',
            module: 'M00',
          ),
        ]
        ..conceptPages = [page];
      final store = LocalReviewStore();
      await store.enqueueRemediation(['m00-vector-geometry']);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(
            body: StudyScreen(controller: controller, api: api, store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('All caught up'), findsOneWidget);
      expect(find.text('Reread: Vector geometry primer'), findsOneWidget);
      await tester.tap(find.text('Reread: Vector geometry primer'));
      await tester.pumpAndSettle();
      expect(find.text('Vector geometry primer'), findsOneWidget);
      expect(find.byType(PrimerScreen), findsOneWidget);

      Navigator.of(tester.element(find.byType(PrimerScreen))).pop();
      await tester.pumpAndSettle();
      expect(await store.remediationQueue(), isEmpty);
    });
  });
}

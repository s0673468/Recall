import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_acceptance_fixture.dart';

// Invented cards, events and HTTP responses only. The .invalid client uses
// MockClient, so no review can reach a server.
const _waitLimit = Duration(seconds: 5);

Map<String, dynamic> _entry(int cardId, String eventId) => {
  'card_id': cardId,
  'guid': 'invented-guid-$cardId',
  'stability': 2.5,
  'difficulty': 4.0,
  'due': '2026-10-20T12:00:00.000Z',
  'state': 2,
  'reps': 3,
  'lapses': 0,
  'last_review': '2026-10-16T12:00:00.000Z',
  'rating': 3,
  'elapsed_ms': 4000,
  'device': 'android',
  'client_id': eventId,
};

typedef _Respond = http.Response Function(http.Request request);

http.Response _json(http.Request request, int status, Object body) =>
    http.Response(
      jsonEncode(body),
      status,
      request: request,
      headers: {'content-type': 'application/json'},
    );

// What PostgREST returns when a pre-008 apply_review hits the card FK.
http.Response _foreignKeyRefusal(http.Request request) => _json(request, 409, {
  'code': '23503',
  'details': 'Key (card_id) is not present in table "cards".',
  'hint': null,
  'message':
      'insert or update on table "review_log" violates foreign key '
      'constraint "review_log_card_id_fkey"',
});

class _QuietAuthRecallApi extends RecallApi {
  const _QuietAuthRecallApi(super.client);

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();
}

/// Production RecallApi + controller flush + unscoped store; only the HTTP
/// transport is scripted, per event id.
class _Server {
  final requests = <String>[];
  final responses = <String, _Respond>{};

  late final SupabaseClient client = SupabaseClient(
    'https://recall-park.invalid',
    'invented-public-key',
    httpClient: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final eventId = body['p_client_event_id'] as String;
      requests.add(eventId);
      final respond = responses[eventId];
      if (respond == null) throw StateError('unscripted event $eventId');
      return respond(request);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  ReviewController controller(LocalReviewStore store) => ReviewController(
    api: _QuietAuthRecallApi(client),
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
  );
}

final _now = DateTime(2026, 10, 16, 12);

class _FixtureApi extends SanitizedRecallApi {
  _FixtureApi()
    : super(
        dataset: SanitizedRecallDataset(
          now: _now,
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          cards: [
            for (var id = 601; id <= 640; id++)
              ReviewCard(
                id: id,
                guid: 'invented-park-$id',
                deckId: 1,
                front: 'Invented front $id',
                back: 'Invented back $id',
                hasLatex: false,
                stability: 4,
                difficulty: 5,
                due: id <= 620
                    ? _now.subtract(const Duration(days: 1))
                    : _now.add(const Duration(hours: 2)),
                state: 2,
                reps: 3,
                lapses: 0,
                lastReview: _now.subtract(const Duration(days: 5)),
                cloudSeen: true,
              ),
          ],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.rich,
      );

  static const deletedCardId = 999;
  final attempts = <int>[];

  /// Cards hard-deleted on the server; a pre-008 RPC refuses their reviews.
  final deletedCardIds = <int>{deletedCardId};

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    final cardId = (entry['card_id'] as num).toInt();
    attempts.add(cardId);
    if (online && deletedCardIds.contains(cardId)) {
      throw const PostgrestException(
        message: 'violates foreign key constraint "review_log_card_id_fkey"',
        code: '23503',
      );
    }
    return super.applyReview(entry);
  }
}

/// Drives StudyScreen's header from a fixed state, without persistence.
class _StateController extends ChangeNotifier implements ReviewController {
  _StateController(this.state);

  @override
  ReviewState state;

  @override
  String? get flagNotice => null;

  @override
  bool get rateInFlight => false;

  @override
  bool get canUndo => false;

  @override
  bool get undoInFlight => false;

  @override
  int get remediationRevision => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the per-send and batched attempt marks of a flush (#136).
class _RecordingStore extends LocalReviewStore {
  final single = <Object>[];
  final batches = <List<Object>>[];

  @override
  Future<bool> markReviewAttempted(Object clientId, {String? ownerScope}) {
    single.add(clientId);
    return super.markReviewAttempted(clientId, ownerScope: ownerScope);
  }

  @override
  Future<Set<Object>> markReviewsAttempted(
    Iterable<Object> clientIds, {
    String? ownerScope,
  }) {
    batches.add([...clientIds]);
    return super.markReviewsAttempted(clientIds, ownerScope: ownerScope);
  }
}

Future<T> _bounded<T>(Future<T> future) => future.timeout(_waitLimit);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('permanent refusal on the transport path', () {
    late _Server server;
    late LocalReviewStore store;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      server = _Server();
      addTearDown(server.client.dispose);
      store = LocalReviewStore();
    });

    test('parks only the refused review and delivers the later ones', () async {
      server.responses['ev-orphan'] = _foreignKeyRefusal;
      server.responses['ev-b'] = (r) => _json(r, 200, 101);
      server.responses['ev-c'] = (r) => _json(r, 200, 102);
      await store.enqueueReview(_entry(41, 'ev-orphan'));
      await store.enqueueReview(_entry(42, 'ev-b'));
      await store.enqueueReview(_entry(43, 'ev-c'));
      final controller = server.controller(store);
      addTearDown(controller.dispose);

      await controller.syncPending();

      expect(server.requests, ['ev-orphan', 'ev-b', 'ev-c']);
      final kept = await store.outbox();
      expect(kept.map((e) => e['client_id']), ['ev-orphan']);
      expect(kept.single['delivery_attempted'], isTrue);
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, 1);

      // Parked: not re-sent on every flush, and new reviews still go out.
      await store.enqueueReview(_entry(44, 'ev-d'));
      server.responses['ev-d'] = (r) => _json(r, 200, 103);
      await controller.syncPending();
      expect(server.requests, ['ev-orphan', 'ev-b', 'ev-c', 'ev-d']);
      expect((await store.outbox()).map((e) => e['client_id']), [
        'ev-orphan',
      ]);
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, 1);
    });

    for (final failure in <({String name, _Respond respond})>[
      (
        name: 'a server error',
        respond: (r) =>
            _json(r, 503, {'code': 'PGRST500', 'message': 'invented outage'}),
      ),
      (
        name: 'an RLS refusal',
        respond: (r) => _json(r, 403, {
          'code': '42501',
          'message': 'new row violates row-level security policy',
        }),
      ),
      (
        name: 'a lost connection',
        respond: (r) =>
            throw http.ClientException('invented airplane mode', r.url),
      ),
    ]) {
      test('${failure.name} still holds every later review', () async {
        server.responses['ev-a'] = failure.respond;
        await store.enqueueReview(_entry(41, 'ev-a'));
        await store.enqueueReview(_entry(42, 'ev-b'));
        final controller = server.controller(store);
        addTearDown(controller.dispose);

        await controller.syncPending();
        await controller.syncPending();

        expect(server.requests, ['ev-a', 'ev-a']);
        expect((await store.outbox()).map((e) => e['client_id']), [
          'ev-a',
          'ev-b',
        ]);
        expect(controller.state.syncErrors, 0);
      });
    }

    test('a park before the first delivery keeps the batched marks', () async {
      final recording = _RecordingStore();
      server.responses['ev-orphan'] = _foreignKeyRefusal;
      server.responses['ev-b'] = (r) => _json(r, 200, 101);
      server.responses['ev-c'] = (r) => _json(r, 200, 102);
      server.responses['ev-d'] = (r) => _json(r, 200, 103);
      for (final (card, id) in [
        (41, 'ev-orphan'),
        (42, 'ev-b'),
        (43, 'ev-c'),
        (44, 'ev-d'),
      ]) {
        await recording.enqueueReview(_entry(card, id));
      }
      final controller = server.controller(recording);
      addTearDown(controller.dispose);

      await controller.syncPending();

      expect(server.requests, ['ev-orphan', 'ev-b', 'ev-c', 'ev-d']);
      // The refusal proves nothing about the transport: the first delivery
      // does, and only then is the rest marked in one write.
      expect(recording.single, ['ev-orphan', 'ev-b']);
      expect(recording.batches, [
        ['ev-c', 'ev-d'],
      ]);
      final kept = await recording.outbox();
      expect(kept.map((e) => e['client_id']), ['ev-orphan']);
      expect(kept.single['delivery_attempted'], isTrue);
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, 1);

      // The next pass skips the parked review without marking it again.
      await controller.syncPending();
      expect(server.requests, hasLength(4));
      expect(recording.single, ['ev-orphan', 'ev-b']);
      expect(recording.batches, hasLength(1));
    });

    test('a restart retries the parked review and drains its ACK', () async {
      server.responses['ev-orphan'] = _foreignKeyRefusal;
      await store.enqueueReview(_entry(41, 'ev-orphan'));
      final first = server.controller(store);
      await first.syncPending();
      expect(first.state.syncErrors, 1);
      first.dispose();

      // 008 acknowledges a review for a hard-deleted card with 0.
      server.responses['ev-orphan'] = (r) => _json(r, 200, 0);
      final restarted = server.controller(store);
      addTearDown(restarted.dispose);
      await restarted.syncPending();

      expect(server.requests, ['ev-orphan', 'ev-orphan']);
      expect(await store.outbox(), isEmpty);
      expect(restarted.state.pendingSync, 0);
      expect(restarted.state.syncErrors, 0);
    });
  });

  test('isPermanentReviewRejection accepts only integrity violations', () {
    for (final code in ['23503', '23502', '23514', '23P01']) {
      expect(
        RecallApi.isPermanentReviewRejection(
          PostgrestException(message: 'invented', code: code),
        ),
        isTrue,
        reason: code,
      );
    }
    for (final error in <Object>[
      const PostgrestException(message: 'invented', code: '42501'),
      const PostgrestException(message: 'invented', code: 'PGRST301'),
      const PostgrestException(message: 'invented', code: '503'),
      const PostgrestException(message: 'invented'),
      const FormatException('invalid_review_log_id_ack'),
      StateError('invented offline'),
    ]) {
      expect(RecallApi.isPermanentReviewRejection(error), isFalse);
    }
  });

  group('controller flow with a parked review', () {
    late _FixtureApi api;
    late LocalReviewStore store;
    late ReviewController controller;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      api = _FixtureApi();
      store = LocalReviewStore();
      await _bounded(store.activateOwner(api.currentUser!.id));
      controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        haptics: const ReviewHaptics(),
        clock: () => _now,
      );
      addTearDown(() {
        controller.dispose();
        api.disposeFixture();
      });
      await _bounded(controller.load(deckId: 1));
      expect(controller.state.offline, isFalse);
    });

    Future<List<Object?>> queuedCardIds() async => [
      for (final entry in await _bounded(store.outbox())) entry['card_id'],
    ];

    test('a rating for a deleted card parks; the next one delivers', () async {
      final cardA = controller.state.current!.id;
      api.deletedCardIds.add(cardA);
      controller.flip();
      await _bounded(controller.rate(Rating.good));
      await _bounded(controller.syncPending());
      expect(controller.state.syncErrors, 1);

      final cardB = controller.state.current!.id;
      controller.flip();
      await _bounded(controller.rate(Rating.good));
      await _bounded(controller.syncPending());

      expect(api.attempts, [cardA, cardB]);
      expect(api.appliedReviewCardIds, [cardB]);
      expect(await queuedCardIds(), [cardA]);
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, 1);
    });

    test('Undo of an unsent rating keeps the parked review', () async {
      // A review queued earlier for a card hard-deleted since.
      await _bounded(
        store.enqueueReview(
          _entry(_FixtureApi.deletedCardId, 'invented-orphan-event'),
        ),
      );
      await _bounded(controller.syncPending());
      expect(controller.state.syncErrors, 1);

      // Offline, a new rating stays unsent and Undo restores it.
      api.online = false;
      await _bounded(controller.load(deckId: 1));
      expect(controller.state.offline, isTrue);
      final cardA = controller.state.current!.id;
      controller.flip();
      await _bounded(controller.rate(Rating.good));
      expect(await queuedCardIds(), [_FixtureApi.deletedCardId, cardA]);
      expect(controller.canUndo, isTrue);
      await _bounded(controller.undo());

      expect(controller.state.current?.id, cardA);
      expect(controller.state.showBack, isFalse);
      final kept = await _bounded(store.outbox());
      expect(kept.map((e) => e['client_id']), ['invented-orphan-event']);
      expect(kept.single['delivery_attempted'], isTrue);

      // Back online, the parked review is not re-sent and Undo stayed local.
      api.online = true;
      await _bounded(controller.syncPending());
      expect(api.attempts, [_FixtureApi.deletedCardId]);
      expect(api.appliedReviewCardIds, isEmpty);
      expect(controller.state.syncErrors, 1);
    });

    test('a delivery after a parked review clears offline', () async {
      await _bounded(
        store.enqueueReview(
          _entry(_FixtureApi.deletedCardId, 'invented-orphan-event'),
        ),
      );
      await _bounded(controller.syncPending());
      expect(controller.state.syncErrors, 1);

      api.online = false;
      await _bounded(controller.load(deckId: 1));
      expect(controller.state.offline, isTrue);
      final cardA = controller.state.current!.id;
      controller.flip();
      await _bounded(controller.rate(Rating.good));
      expect(api.appliedReviewCardIds, isEmpty);

      api.online = true;
      await _bounded(controller.syncPending());

      expect(api.appliedReviewCardIds, [cardA]);
      expect(await queuedCardIds(), [_FixtureApi.deletedCardId]);
      expect(controller.state.offline, isFalse);
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, 1);
    });

    test('a sync that only parks a review keeps the session offline', () async {
      api.online = false;
      await _bounded(controller.load(deckId: 1));
      expect(controller.state.offline, isTrue);
      await _bounded(
        store.enqueueReview(
          _entry(_FixtureApi.deletedCardId, 'invented-orphan-event'),
        ),
      );

      api.online = true;
      await _bounded(controller.syncPending());

      // Only a delivery clears offline, as for any flush that delivers nothing.
      expect(api.attempts, [_FixtureApi.deletedCardId]);
      expect(api.appliedReviewCardIds, isEmpty);
      expect(controller.state.offline, isTrue);
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, 1);
    });

    test('Keep going is not held offline by a parked review', () async {
      await _bounded(
        store.enqueueReview(
          _entry(_FixtureApi.deletedCardId, 'invented-orphan-event'),
        ),
      );
      await _bounded(controller.syncPending());
      expect(controller.state.syncErrors, 1);

      await _bounded(controller.keepGoing());

      expect(controller.state.offline, isFalse);
      expect(controller.state.loading, isFalse);
      expect(controller.state.queue, isNotEmpty);
      expect(await queuedCardIds(), [_FixtureApi.deletedCardId]);
    });
  });

  testWidgets('the study header separates refused reviews from syncing', (
    tester,
  ) async {
    final card = ReviewCard(
      id: 7,
      guid: 'invented-header',
      deckId: 1,
      front: 'Invented front',
      back: 'Invented back',
      hasLatex: false,
      stability: 3,
      difficulty: 5,
      due: DateTime.utc(2026, 10, 1),
      state: 2,
      reps: 3,
      lapses: 0,
      lastReview: DateTime.utc(2026, 9, 28),
    );
    Future<void> pump(int pendingSync, int syncErrors) async {
      final controller = _StateController(
        ReviewState(
          loading: false,
          queue: [card],
          pendingSync: pendingSync,
          syncErrors: syncErrors,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyScreen(controller: controller, nativeIos: false),
          ),
        ),
      );
    }

    await pump(3, 1);
    expect(find.text('2 syncing · 1 couldn’t sync'), findsOneWidget);
    await pump(1, 1);
    expect(find.text('1 couldn’t sync'), findsOneWidget);
    await pump(2, 0);
    expect(find.text('2 syncing'), findsOneWidget);
  });

  testWidgets('the study header keeps the server-error label with refusals', (
    tester,
  ) async {
    final card = ReviewCard(
      id: 7,
      guid: 'invented-header',
      deckId: 1,
      front: 'Invented front',
      back: 'Invented back',
      hasLatex: false,
      stability: 3,
      difficulty: 5,
      due: DateTime.utc(2026, 10, 1),
      state: 2,
      reps: 3,
      lapses: 0,
      lastReview: DateTime.utc(2026, 9, 28),
    );
    Future<void> pump({required bool serverError}) async {
      final controller = _StateController(
        ReviewState(
          loading: false,
          queue: [card],
          offline: true,
          serverError: serverError,
          pendingSync: 3,
          syncErrors: 1,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyScreen(controller: controller, nativeIos: false),
          ),
        ),
      );
    }

    await pump(serverError: true);
    expect(find.text('Server error · 3 waiting to sync'), findsOneWidget);
    await pump(serverError: false);
    expect(find.text('Offline · 3 waiting to sync'), findsOneWidget);
  });
}

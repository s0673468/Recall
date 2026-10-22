import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:fsrs/fsrs.dart' show Rating;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

/// All rows, auth identity and transport responses are generated in this file.
/// The inherited RecallApi methods, controller and local store remain real.
class SyntheticRecallFlow {
  SyntheticRecallFlow._(
    this.cards,
    this.httpFixture,
    this.client,
    this.api,
    this.store,
    this.controller,
  );

  final List<ReviewCard> cards;
  final SyntheticRecallHttp httpFixture;
  final SupabaseClient client;
  final SyntheticAuthRecallApi api;
  final TimedLocalReviewStore store;
  final ReviewController controller;

  static Future<SyntheticRecallFlow> create({
    required int cardCount,
    required int seededOutbox,
    required bool warmCache,
  }) async {
    final cards = List<ReviewCard>.generate(
      cardCount,
      (index) => syntheticCard(index + 1),
      growable: false,
    );
    final transport = SyntheticRecallHttp(cards);
    final client = SupabaseClient(
      'https://recall-bench.invalid',
      'synthetic-public-key',
      httpClient: MockClient(transport.respond),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final api = SyntheticAuthRecallApi(client);
    final store = TimedLocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      haptics: const ReviewHaptics(),
    );
    final flow = SyntheticRecallFlow._(
      cards,
      transport,
      client,
      api,
      store,
      controller,
    );
    try {
      await store.activateOwner(api.currentUser!.id);
      if (warmCache) {
        await store.saveSnapshot(
          decks: const [DeckRow(deckId: 1, name: 'ML')],
          queue: cards,
          globalDueCount: cardCount,
          globalDueUpdatedAt: DateTime.now().toUtc(),
        );
      }
      if (seededOutbox > 0) {
        // Seed already-durable, unrelated synthetic events outside the measured
        // phase. The measured load/drain still uses the real LocalReviewStore.
        final prefs = await SharedPreferences.getInstance();
        final entries = List<Map<String, dynamic>>.generate(
          seededOutbox,
          syntheticPendingReview,
          growable: false,
        );
        await prefs.setString(
          'recall_outbox_v1:owner:${store.activeOwnerScope}',
          jsonEncode(entries),
        );
      }
      return flow;
    } catch (_) {
      await flow.dispose();
      rethrow;
    }
  }

  Future<void> load() => controller.load();

  Future<void> selectDeck(int deckId) => controller.selectDeck(deckId);

  Future<void> rateFirstGood() async {
    if (controller.state.current == null) {
      throw StateError('Synthetic queue has no visible card to rate');
    }
    controller.flip();
    await controller.rate(Rating.good);
  }

  Future<void> close() => dispose();

  Future<void> dispose() async {
    controller.dispose();
    try {
      // This joins earlier snapshot/outbox work on the store's real lock.
      await store.outbox();
      await store.flagOutbox();
    } finally {
      client.dispose();
    }
  }
}

/// Times the real serialized append, including its platform write response.
class TimedLocalReviewStore extends LocalReviewStore {
  int lastEnqueueAckUs = 0;

  @override
  Future<int> enqueueReview(
    Map<String, dynamic> entry, {
    String? ownerScope,
    bool Function()? canWrite,
  }) async {
    final watch = Stopwatch()..start();
    final count = await super.enqueueReview(
      entry,
      ownerScope: ownerScope,
      canWrite: canWrite,
    );
    watch.stop();
    lastEnqueueAckUs = watch.elapsedMicroseconds;
    return count;
  }
}

ReviewCard syntheticCard(int id) => ReviewCard(
  id: id,
  guid: 'synthetic-card-$id',
  deckId: 1,
  front: 'Synthetic front $id',
  back: 'Synthetic back $id',
  hasLatex: false,
  stability: 4,
  difficulty: 5,
  due: DateTime.utc(2020, 1, 1),
  state: 2,
  reps: 3,
  lapses: 0,
  lastReview: DateTime.utc(2019, 12, 28),
  cloudSeen: true,
);

Map<String, dynamic> syntheticPendingReview(int index) => {
  'card_id': 100000 + index,
  'guid': 'synthetic-pending-$index',
  'stability': 4.0,
  'difficulty': 5.0,
  'due': DateTime.utc(2020, 1, 2).toIso8601String(),
  'state': 2,
  'reps': 4,
  'lapses': 0,
  'last_review': DateTime.utc(2020, 1, 1).toIso8601String(),
  'rating': 3,
  'elapsed_ms': 0,
  'device': 'android',
  'lapsed': false,
  'client_id': 'synthetic-seed-$index',
  'delivery_attempted': false,
};

/// Only auth is synthetic. Every data call runs the real RecallApi method.
class SyntheticAuthRecallApi extends RecallApi {
  SyntheticAuthRecallApi(super.client);

  int fetchQueueUs = 0;
  int applyReviewUs = 0;

  final User _syntheticUser = User(
    id: 'synthetic-benchmark-owner',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    email: 'benchmark@example.invalid',
    createdAt: DateTime.utc(2020).toIso8601String(),
  );

  @override
  User? get currentUser => _syntheticUser;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    final watch = Stopwatch()..start();
    final trace = developer.TimelineTask()
      ..start('recall.synthetic.api_fetch_queue');
    try {
      return await super.fetchQueue(
        deckId: deckId,
        includedDeckIds: includedDeckIds,
        newLimit: newLimit,
        order: order,
        excludeCardIds: excludeCardIds,
      );
    } finally {
      watch.stop();
      fetchQueueUs += watch.elapsedMicroseconds;
      trace.finish();
    }
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    final watch = Stopwatch()..start();
    final trace = developer.TimelineTask()
      ..start('recall.synthetic.api_apply_review');
    try {
      return await super.applyReview(entry);
    } finally {
      watch.stop();
      applyReviewUs += watch.elapsedMicroseconds;
      trace.finish();
    }
  }
}

class SyntheticRecallHttp {
  SyntheticRecallHttp(this.cards);

  final List<ReviewCard> cards;
  bool deliverReviews = false;
  int nextReviewLogId = 1;
  int handlerUs = 0;
  final Map<String, int> counts = {
    'decks': 0,
    'cards_due': 0,
    'cards_new': 0,
    'cards_revalidation': 0,
    'review_log': 0,
    'user_settings': 0,
    'note_flags': 0,
    'deck_counts': 0,
    'apply_review': 0,
  };

  int get totalRequests => counts.values.fold(0, (sum, count) => sum + count);
  Map<String, int> snapshotCounts() => Map<String, int>.from(counts);

  Future<http.Response> respond(http.Request request) async {
    if (request.url.host != 'recall-bench.invalid') {
      throw StateError('Benchmark transport escaped .invalid');
    }
    final watch = Stopwatch()..start();
    final path = request.url.path;
    final query = request.url.queryParameters;
    late final String kind;
    late final String body;
    var status = 200;
    if (path.endsWith('/decks')) {
      _require(request.method == 'GET' && query['select'] == 'deck_id,name');
      kind = 'decks';
      body = query['deck_id'] == 'gt.1' ? '[]' : '[{"deck_id":1,"name":"ML"}]';
    } else if (path.endsWith('/cards')) {
      _require(request.method == 'GET' && query.containsKey('select'));
      _require(query['deleted'] == 'eq.false');
      _require(query['suspended'] == 'eq.false');
      if (query['state'] == 'neq.0') {
        _require(query['order'] == 'due.asc.nullslast,id.asc.nullslast');
        _require(
          query['notes.deck_id'] == 'in.(1)' ||
              query['notes.deck_id'] == 'eq.1',
        );
        kind = 'cards_due';
        final cursor = RegExp(r'id\.gt\.(\d+)').firstMatch(query['or'] ?? '');
        final afterId = cursor == null ? 0 : int.parse(cursor.group(1)!);
        final pageSize = int.tryParse(query['limit'] ?? '') ?? 500;
        body = jsonEncode([
          for (final card in cards.skip(afterId).take(pageSize)) _cardRow(card),
        ]);
      } else if (query['state'] == 'eq.0') {
        _require(
          query['notes.deck_id'] == 'in.(1)' ||
              query['notes.deck_id'] == 'eq.1',
        );
        kind = 'cards_new';
        body = '[]';
      } else {
        _require(query['reps'] == 'gt.0');
        kind = 'cards_revalidation';
        body = '[]';
      }
    } else if (path.endsWith('/review_log')) {
      _require(request.method == 'GET' && query.containsKey('select'));
      kind = 'review_log';
      body = '[]';
    } else if (path.endsWith('/user_settings')) {
      _require(request.method == 'GET' && query['select'] == 'settings_value');
      kind = 'user_settings';
      body = 'null';
    } else if (path.endsWith('/note_flags')) {
      _require(request.method == 'GET' && query['status'] == 'eq.open');
      kind = 'note_flags';
      body = '[]';
    } else if (path.endsWith('/rpc/deck_counts')) {
      _require(request.method == 'POST');
      kind = 'deck_counts';
      body = jsonEncode([
        if (query['deck_id'] != 'gt.1')
          {'deck_id': 1, 'due': cards.length, 'new': 0},
      ]);
    } else if (path.endsWith('/rpc/apply_review')) {
      _require(request.method == 'POST');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      _require(payload['p_client_event_id'] is String);
      _require(payload['p_card_id'] is num);
      kind = 'apply_review';
      if (deliverReviews) {
        body = '${nextReviewLogId++}';
      } else {
        status = 503;
        body = '{"code":"BENCH_OFFLINE","message":"synthetic offline"}';
      }
    } else {
      throw StateError('Unmatched synthetic request: ${request.method} $path');
    }
    counts[kind] = counts[kind]! + 1;
    watch.stop();
    handlerUs += watch.elapsedMicroseconds;
    return http.Response(
      body,
      status,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }

  void _require(bool condition) {
    if (!condition) throw StateError('Synthetic REST query shape changed');
  }

  Map<String, dynamic> _cardRow(ReviewCard card) => {
    'id': card.id,
    'guid': card.guid,
    'stability': card.stability,
    'difficulty': card.difficulty,
    'due': card.due!.toUtc().toIso8601String(),
    'state': card.state,
    'reps': card.reps,
    'lapses': card.lapses,
    'last_review': card.lastReview!.toUtc().toIso8601String(),
    'cloud_seen': true,
    'notes': {
      'front': card.front,
      'back': card.back,
      'has_latex': false,
      'deck_id': 1,
      'latex_svg': null,
      'tags': '',
    },
  };
}

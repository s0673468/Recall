import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/core/background/browser_foreground_sync_coordinator.dart';
import 'package:health_anki_flutter/core/background/browser_sync_platform.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

// Sanitized shared cloud model. RPC replay/conflict semantics themselves have
// detailed coverage in recall_test.dart; this suite tests the browser wiring
// with the real review controller, owner-scoped cache and durable preferences.
class _Cloud {
  Map<String, dynamic> prefs = const RecallPrefs().toJson();
  final cards = <ReviewCard>[];
  final reviews = <Map<String, dynamic>>[];
}

class _Api extends RecallApi {
  final _Cloud cloud;
  bool offline = false;
  int queueFetches = 0;
  int? queueLimit;

  _Api(this.cloud)
    : super(
        SupabaseClient(
          'https://recall.invalid',
          'test-publishable-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  void _connected() {
    if (offline) throw StateError('offline');
  }

  @override
  User get currentUser => User(
    id: 'same-owner',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime.utc(2026).toIso8601String(),
  );

  @override
  Stream<AuthState> get onAuthStateChange => const Stream.empty();
  @override
  String get device => 'test-browser';
  @override
  Future<List<DeckRow>> fetchDecks() async {
    _connected();
    return const [DeckRow(deckId: 1, name: 'Fixture')];
  }

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async {
    _connected();
    return null;
  }

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    _connected();
    queueFetches++;
    queueLimit = newLimit;
    return cloud.cards.where((c) => !excludeCardIds.contains(c.id)).toList();
  }

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async {
    _connected();
    return {1: (due: cloud.cards.length, neu: 0)};
  }

  @override
  Future<Set<int>> fetchHiddenCardIds() async {
    _connected();
    return {};
  }

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    _connected();
    return const [];
  }

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    _connected();
    return Map.from(cloud.prefs);
  }

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    _connected();
    cloud.prefs = Map.from(value);
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    _connected();
    final previous = cloud.reviews.indexWhere(
      (row) => row['client_id'] == entry['client_id'],
    );
    if (previous >= 0) return previous + 1;
    cloud.reviews.add(Map.from(entry));
    cloud.cards.removeWhere((card) => card.id == entry['card_id']);
    return cloud.reviews.length;
  }
}

class _Browser implements BrowserSyncPlatform {
  @override
  bool get supported => true;
  @override
  bool get visible => true;
  @override
  bool online = true;
  @override
  void start(void Function() onWake) {}
  @override
  void dispose() {}
}

class _Website {
  final _Api api;
  final LocalReviewStore store;
  final RecallPrefsController prefs;
  final ReviewController controller;
  final _Browser browser;
  final BrowserForegroundSyncCoordinator coordinator;
  bool _disposed = false;

  _Website(this.api, this.store, this.prefs, this.controller, this.browser)
    : coordinator = BrowserForegroundSyncCoordinator(
        platform: browser,
        hasSession: () => controller.currentUser != null,
        syncPending: controller.syncPending,
        refreshIfIdle: () => controller.refreshIfIdle(maxAge: Duration.zero),
      )..start();

  static Future<_Website> open(_Api api) async {
    final store = LocalReviewStore();
    final prefs = RecallPrefsController(api: api);
    await store.activateOwner(api.currentUser.id);
    await prefs.activateOwner(api.currentUser.id);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      prefs: prefs,
      haptics: ReviewHaptics.forPlatform(isWeb: true),
    );
    final site = _Website(api, store, prefs, controller, _Browser());
    addTearDown(site.dispose);
    return site;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    coordinator.dispose();
    controller.dispose();
    prefs.dispose();
    await api.client.dispose();
  }
}

ReviewCard _card(int id) => ReviewCard(
  id: id,
  guid: 'fixture-$id',
  deckId: 1,
  front: 'Fixture question $id',
  back: 'Fixture answer $id',
  hasLatex: false,
  state: 2,
  due: DateTime.utc(2026),
  stability: 8,
  difficulty: 5,
  reps: 2,
  lapses: 0,
  lastReview: DateTime.utc(2025, 12, 25),
);

Future<void> _settleLoads(ReviewController controller) async {
  for (var i = 0; i < 100 && controller.state.loading; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(controller.state.loading, isFalse);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Android cloud prefs reach an idle website through existing sync path',
    () async {
      final cloud = _Cloud();
      final android = _Api(cloud);
      addTearDown(android.client.dispose);
      final site = await _Website.open(_Api(cloud));
      await site.controller.load();

      await android.saveRecallPrefs(
        const RecallPrefs(newLimitDefault: 7, desiredRetention: 0.86).toJson(),
      );
      await site.coordinator.sync();
      await _settleLoads(site.controller);

      expect(site.prefs.value.newLimitDefault, 7);
      expect(site.controller.engine.desiredRetention, 0.86);
      expect(site.api.queueLimit, 7);
    },
  );

  test(
    'remote queue prefs preserve active revealed card; local edit still reloads',
    () async {
      final cloud = _Cloud()..cards.addAll([_card(1), _card(2)]);
      final android = _Api(cloud);
      addTearDown(android.client.dispose);
      final site = await _Website.open(_Api(cloud));
      await site.controller.load();
      site.controller.flip();
      final active = site.controller.state.current;
      final fetches = site.api.queueFetches;

      await android.saveRecallPrefs(
        const RecallPrefs(newLimitDefault: 9, desiredRetention: 0.85).toJson(),
      );
      await site.coordinator.sync();
      await _settleLoads(site.controller);

      expect(site.controller.state.current, same(active));
      expect(site.controller.state.showBack, isTrue);
      expect(site.api.queueFetches, fetches);
      expect(site.prefs.value.newLimitDefault, 9);
      expect(site.prefs.applyingCloudUpdate, isFalse);
      expect(site.controller.engine.desiredRetention, 0.85);

      await site.prefs.update(const RecallPrefs(newLimitDefault: 4));
      await _settleLoads(site.controller);
      expect(site.api.queueFetches, greaterThan(fetches));
      expect(site.api.queueLimit, 4);
    },
  );

  test(
    'reopen offline website replays durable review and prefs exactly once to Android',
    () async {
      final cloud = _Cloud()..cards.addAll([_card(1), _card(2)]);
      final android = _Api(cloud);
      addTearDown(android.client.dispose);
      final first = await _Website.open(_Api(cloud));
      await first.controller.load();
      first.api.offline = true;
      first.browser.online = false;
      first.controller.flip();
      await first.controller.rate(Rating.good);
      await first.prefs.update(const RecallPrefs(newLimitDefault: 11));
      await first.controller.syncPending();
      await _settleLoads(first.controller);
      expect(await first.store.outbox(), hasLength(1));
      await first.dispose();

      final reopened = await _Website.open(_Api(cloud)..offline = true);
      reopened.browser.online = false;
      await reopened.controller.load();
      expect(reopened.controller.state.current?.id, 2);
      expect(reopened.prefs.value.newLimitDefault, 11);

      // A stale phone value must not override the website's pending local edit.
      await android.saveRecallPrefs(
        const RecallPrefs(newLimitDefault: 3).toJson(),
      );
      reopened.api.offline = false;
      reopened.browser.online = true;
      final active = reopened.controller.state.current;
      await reopened.coordinator.sync();
      await reopened.coordinator.sync();

      expect(reopened.controller.state.current, same(active));
      expect(await reopened.store.outbox(), isEmpty);
      expect(cloud.reviews, hasLength(1));
      expect((await android.fetchRecallPrefs())!['new_limit_default'], 11);
      expect((await android.fetchQueue()).map((c) => c.id), [2]);
      final local = await SharedPreferences.getInstance();
      expect(
        local.containsKey(
          RecallPrefsController.pendingKeyForOwner('same-owner'),
        ),
        isFalse,
      );
    },
  );
}

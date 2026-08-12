import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

class _PrefsRecallApi extends RecallApi {
  final authStates = StreamController<AuthState>.broadcast();
  final cloudByOwner = <String, Map<String, dynamic>>{};
  final saved = <({String ownerId, Map<String, dynamic> value})>[];

  User? user;
  bool failSave = false;
  Future<void> Function()? beforeFetchPrefs;
  Future<void> Function(Map<String, dynamic> value)? beforeSavePrefs;
  int prefsFetches = 0;
  int? queueNewLimit;

  _PrefsRecallApi()
    : super(
        SupabaseClient(
          'https://recall.invalid',
          'test-publishable-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  void useOwner(String ownerId) {
    user = User(
      id: ownerId,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
  }

  @override
  User? get currentUser => user;

  @override
  Stream<AuthState> get onAuthStateChange => authStates.stream;

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    prefsFetches++;
    await beforeFetchPrefs?.call();
    final ownerId = user?.id;
    return ownerId == null ? null : cloudByOwner[ownerId];
  }

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    if (failSave) throw StateError('offline');
    final ownerId = user!.id;
    await beforeSavePrefs?.call(value);
    final copy = Map<String, dynamic>.from(value);
    saved.add((ownerId: ownerId, value: copy));
    cloudByOwner[ownerId] = copy;
  }

  @override
  Future<void> signOut() async {
    user = null;
    authStates.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  @override
  Future<List<DeckRow>> fetchDecks() async => const [];

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    queueNewLimit = newLimit;
    return const [];
  }

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async => const {};

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async =>
      const [];

  @override
  Future<FsrsSettings?> fetchFsrsSettings() async => null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('local mirrors are isolated by owner and restored on return', () async {
    final api = _PrefsRecallApi()..useOwner('owner-a');
    addTearDown(api.authStates.close);
    addTearDown(api.client.dispose);
    final prefs = RecallPrefsController(api: api);

    await prefs.activateOwner('owner-a');
    await prefs.update(const RecallPrefs(newLimitDefault: 7));
    await prefs.releaseOwner();

    api.useOwner('owner-b');
    await prefs.activateOwner('owner-b');
    expect(prefs.value, const RecallPrefs());
    await prefs.update(const RecallPrefs(newLimitDefault: 31));
    await prefs.releaseOwner();

    api.useOwner('owner-a');
    await prefs.activateOwner('owner-a');
    expect(prefs.value.newLimitDefault, 7);

    final storage = await SharedPreferences.getInstance();
    expect(
      RecallPrefsController.localKeyForOwner('owner-a'),
      isNot(contains('owner-a')),
    );
    expect(
      storage.getString(RecallPrefsController.localKeyForOwner('owner-a')),
      isNotNull,
    );
    expect(
      storage.getString(RecallPrefsController.localKeyForOwner('owner-b')),
      isNotNull,
    );
  });

  test(
    'failed save survives restart, replays once, and beats stale cloud',
    () async {
      final api = _PrefsRecallApi()
        ..useOwner('owner-a')
        ..failSave = true
        ..cloudByOwner['owner-a'] = const RecallPrefs(
          newLimitDefault: 20,
        ).toJson();
      addTearDown(api.authStates.close);
      addTearDown(api.client.dispose);
      final first = RecallPrefsController(api: api);

      await first.activateOwner('owner-a');
      await first.update(const RecallPrefs(newLimitDefault: 9));

      final storage = await SharedPreferences.getInstance();
      final pendingKey = RecallPrefsController.pendingKeyForOwner('owner-a');
      expect(storage.getString(pendingKey), isNotNull);

      api.failSave = false;
      final restarted = RecallPrefsController(api: api);
      await restarted.activateOwner('owner-a');
      expect(restarted.value.newLimitDefault, 9);

      await restarted.syncOwner();

      expect(api.saved, hasLength(1));
      expect(api.saved.single.value['new_limit_default'], 9);
      expect(storage.getString(pendingKey), isNull);
      expect(restarted.value.newLimitDefault, 9);
      expect(
        api.prefsFetches,
        0,
        reason: 'A just-replayed local value remains authoritative.',
      );
    },
  );

  test(
    'overlapping updates leave the latest cloud value authoritative',
    () async {
      final api = _PrefsRecallApi()..useOwner('owner-a');
      addTearDown(api.authStates.close);
      addTearDown(api.client.dispose);
      final firstSaveGate = Completer<void>();
      var savesStarted = 0;
      api.beforeSavePrefs = (_) async {
        savesStarted++;
        if (savesStarted == 1) await firstSaveGate.future;
      };
      final prefs = RecallPrefsController(api: api);
      await prefs.activateOwner('owner-a');

      final first = prefs.update(const RecallPrefs(newLimitDefault: 7));
      for (var i = 0; i < 20 && savesStarted == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(savesStarted, 1);

      final second = prefs.update(const RecallPrefs(newLimitDefault: 13));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(savesStarted, 1, reason: 'Cloud writes must remain serialized.');

      firstSaveGate.complete();
      await Future.wait([first, second]);

      expect(
        api.saved.map((entry) => entry.value['new_limit_default']),
        orderedEquals([7, 13]),
      );
      expect(api.cloudByOwner['owner-a']?['new_limit_default'], 13);
      final storage = await SharedPreferences.getInstance();
      expect(
        storage.getString(RecallPrefsController.pendingKeyForOwner('owner-a')),
        isNull,
      );
    },
  );

  test('an in-flight owner write never lands in the next account', () async {
    final api = _PrefsRecallApi()..useOwner('owner-a');
    addTearDown(api.authStates.close);
    addTearDown(api.client.dispose);
    final saveStarted = Completer<void>();
    final saveGate = Completer<void>();
    api.beforeSavePrefs = (_) async {
      saveStarted.complete();
      await saveGate.future;
    };
    final prefs = RecallPrefsController(api: api);
    await prefs.activateOwner('owner-a');

    final ownerAUpdate = prefs.update(const RecallPrefs(newLimitDefault: 7));
    await saveStarted.future;
    await prefs.releaseOwner();
    api.useOwner('owner-b');
    await prefs.activateOwner('owner-b');
    saveGate.complete();
    await ownerAUpdate;

    expect(api.saved.single.ownerId, 'owner-a');
    expect(api.cloudByOwner['owner-b'], isNull);
    expect(prefs.activeOwnerId, 'owner-b');
    expect(prefs.value, const RecallPrefs());
  });

  test(
    'signed-in queue waits for local prefs but never waits for cloud',
    () async {
      final api = _PrefsRecallApi()..useOwner('owner-a');
      addTearDown(api.authStates.close);
      addTearDown(api.client.dispose);
      final cloudGate = Completer<void>();
      api.beforeFetchPrefs = () => cloudGate.future;
      SharedPreferences.setMockInitialValues({
        RecallPrefsController.localKeyForOwner('owner-a'):
            '{"new_limit_default":6}',
      });
      final prefs = RecallPrefsController(api: api);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
        beforeSessionLoad: () async {
          final owner = api.currentUser;
          if (owner == null) return;
          await prefs.activateOwner(owner.id);
          unawaited(prefs.syncOwner());
        },
      );
      addTearDown(controller.dispose);

      api.authStates.add(const AuthState(AuthChangeEvent.signedIn, null));
      for (var i = 0; i < 100 && api.queueNewLimit == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(api.queueNewLimit, 6);
      expect(api.prefsFetches, 1);
      expect(cloudGate.isCompleted, isFalse);
      cloudGate.complete();
    },
  );

  test('successful sign-out releases in-memory owner preferences', () async {
    final api = _PrefsRecallApi()..useOwner('owner-a');
    addTearDown(api.authStates.close);
    addTearDown(api.client.dispose);
    final prefs = RecallPrefsController(api: api);
    await prefs.activateOwner('owner-a');
    await prefs.update(const RecallPrefs(newLimitDefault: 8));
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      prefs: prefs,
      afterSignOut: prefs.releaseOwner,
    );
    addTearDown(controller.dispose);

    await controller.signOut();

    expect(prefs.activeOwnerId, isNull);
    expect(prefs.value, const RecallPrefs());
    expect(prefs.hasStoredPrefs, isFalse);
  });

  test('foreground sync replays a pending preference write', () async {
    final api = _PrefsRecallApi()
      ..useOwner('owner-a')
      ..failSave = true;
    addTearDown(api.authStates.close);
    addTearDown(api.client.dispose);
    final prefs = RecallPrefsController(api: api);
    await prefs.activateOwner('owner-a');
    await prefs.update(const RecallPrefs(newLimitDefault: 11));
    final pendingKey = RecallPrefsController.pendingKeyForOwner('owner-a');
    final storage = await SharedPreferences.getInstance();
    expect(storage.getString(pendingKey), isNotNull);

    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      prefs: prefs,
    );
    addTearDown(controller.dispose);
    api.failSave = false;

    await controller.syncPending();

    expect(api.saved, hasLength(1));
    expect(api.saved.single.value['new_limit_default'], 11);
    expect(storage.getString(pendingKey), isNull);
  });

  test('external sign-out sanitizes a local release failure', () async {
    final api = _PrefsRecallApi()..useOwner('owner-a');
    addTearDown(api.authStates.close);
    addTearDown(api.client.dispose);
    final storage = await SharedPreferences.getInstance();
    var failLocalLoad = false;
    final prefs = RecallPrefsController(
      api: api,
      prefsLoader: () async {
        if (failLocalLoad) throw StateError('private local failure');
        return storage;
      },
    );
    await prefs.activateOwner('owner-a');
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      prefs: prefs,
    );
    addTearDown(controller.dispose);

    failLocalLoad = true;
    api.user = null;
    api.authStates.add(const AuthState(AuthChangeEvent.signedOut, null));
    for (var i = 0; i < 10 && prefs.activeOwnerId != null; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(prefs.activeOwnerId, isNull);
    expect(prefs.value, const RecallPrefs());
  });
}

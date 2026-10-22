import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/recall_test_harness.dart';

class _OfflineSettingsApi extends FakeRecallApi {
  _OfflineSettingsApi() : super([]);

  bool offline = true;

  void useOwner(String owner) {
    user = User(
      id: owner,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    );
  }

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    if (offline) throw StateError('synthetic offline storage');
    await super.saveRecallPrefs(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'signed-in offline edits immediately apply to scheduler and queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = _OfflineSettingsApi()..useOwner('synthetic-a');
      final prefs = RecallPrefsController(api: api);
      addTearDown(prefs.dispose);
      await prefs.activateOwner('synthetic-a');
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final fetches = api.queueFetches;

      await prefs.update(prefs.value.copyWith(desiredRetention: 0.97));
      expect(engine.desiredRetention, 0.97);
      expect(
        api.queueFetches,
        fetches,
        reason: 'Retention needs no queue reload.',
      );

      await prefs.update(
        prefs.value.copyWith(
          newLimitDefault: 0,
          newOrder: NewOrder.newestFirst,
        ),
      );
      for (var i = 0; i < 200 && api.lastNewLimit != 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.lastNewLimit, 0);
      expect(api.lastOrder, NewOrder.newestFirst);

      await prefs.update(prefs.value.withDeckOverride(1, 3));
      await controller.selectDeck(1);
      expect(api.lastNewLimit, 3);
      await prefs.update(prefs.value.withDeckOverride(1, null));
      for (var i = 0; i < 200 && api.lastNewLimit != 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.lastNewLimit, 0);

      final storage = await SharedPreferences.getInstance();
      final pendingKey = RecallPrefsController.pendingKeyForOwner(
        'synthetic-a',
      );
      expect(jsonDecode(storage.getString(pendingKey)!), prefs.value.toJson());
      api.offline = false;
      await prefs.syncOwner();
      expect(api.savedRecallPrefs, [prefs.value.toJson()]);
      expect(storage.get(pendingKey), isNull);

      final restarted = RecallPrefsController(api: api);
      addTearDown(restarted.dispose);
      await restarted.activateOwner('synthetic-a');
      expect(restarted.value, prefs.value);
      api.useOwner('synthetic-b');
      await restarted.activateOwner('synthetic-b');
      expect(restarted.value, const RecallPrefs());
      api.useOwner('synthetic-a');
      await restarted.activateOwner('synthetic-a');
      expect(restarted.value, prefs.value);
    },
  );
}

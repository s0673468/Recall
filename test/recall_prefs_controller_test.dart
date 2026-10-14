import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_test_harness.dart';

void main() {
  // The former single recall_test.dart initialized the test binding for every
  // test, because it also declared testWidgets. Keep that environment.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecallPrefsController', () {
    test('loads the cloud row and mirrors it locally', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()]);
      api.recallPrefsRow = {
        'new_limit_default': 15,
        'desired_retention': 0.85,
        'new_order': 'random',
      };
      final controller = RecallPrefsController(api: api);
      await controller.load();
      expect(controller.hasStoredPrefs, isTrue);
      expect(controller.value.newLimitDefault, 15);
      expect(controller.value.desiredRetention, 0.85);
      expect(controller.value.newOrder, NewOrder.random);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(RecallPrefsController.localKey), isNotNull);
    });

    test('no cloud row and no mirror stays at defaults (unstored)', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = RecallPrefsController(
        api: FakeRecallApi([testCard()]),
      );
      await controller.load();
      expect(controller.hasStoredPrefs, isFalse);
      expect(controller.value, const RecallPrefs());
    });

    test('local mirror hydrates before cloud (offline)', () async {
      SharedPreferences.setMockInitialValues({
        RecallPrefsController.localKey: jsonEncode(
          const RecallPrefs(newLimitDefault: 9).toJson(),
        ),
      });
      final controller = RecallPrefsController(
        api: FakeRecallApi([testCard()]),
      );
      await controller.load();
      expect(controller.value.newLimitDefault, 9);
      expect(controller.hasStoredPrefs, isTrue);
    });

    test('update() writes local + cloud and flips hasStoredPrefs', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()]);
      final controller = RecallPrefsController(api: api);
      await controller.update(const RecallPrefs(desiredRetention: 0.8));
      expect(controller.hasStoredPrefs, isTrue);
      expect(api.savedRecallPrefs.single['desired_retention'], 0.8);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(RecallPrefsController.localKey), isNotNull);
    });
  });

  group('ReviewController prefs', () {
    ReviewCard reviewCard() => testCard(
      id: 5,
      state: 2,
      stability: 10,
      difficulty: 5,
      reps: 3,
      due: DateTime.utc(2026, 6, 1),
      lastReview: DateTime.utc(2026, 5, 25),
    );

    Future<void> drainUntil(bool Function() cond) async {
      for (var i = 0; i < 200 && !cond(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('fresh install uses limit 20, oldest-first, retention 0.9', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()]);
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.lastNewLimit, 20);
      expect(api.lastOrder, NewOrder.oldestFirst);
      expect(engine.desiredRetention, 0.9);
    });

    test('cloud prefs drive limit + retention', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()]);
      api.recallPrefsRow = {'new_limit_default': 7, 'desired_retention': 0.85};
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final engine = FsrsEngine();
      final controller = ReviewController(
        api: api,
        engine: engine,
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.lastNewLimit, 7);
      expect(engine.desiredRetention, 0.85);
    });

    test('per-deck override applies only to that deck', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([
        testCard(id: 1, deckId: 1),
        testCard(id: 2, deckId: 2),
      ]);
      api.recallPrefsRow = {
        'new_limit_default': 20,
        'per_deck': {
          '2': {'new_limit': 7},
        },
      };
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.selectDeck(2);
      expect(api.lastNewLimit, 7);
      await controller.selectDeck(null);
      expect(api.lastNewLimit, 20);
    });

    test('changing retention invalidates and re-prices the preview', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([reviewCard()]);
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();

      final before = controller.previewCurrent()[Rating.good];
      await prefs.update(const RecallPrefs(desiredRetention: 0.97));
      final after = controller.previewCurrent()[Rating.good];
      expect(after, isNot(before));
    });

    test('changing the new-limit reloads the queue', () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeRecallApi([testCard()]);
      final prefs = RecallPrefsController(api: api);
      await prefs.load();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(api.lastNewLimit, 20);

      await prefs.update(const RecallPrefs(newLimitDefault: 5));
      await drainUntil(() => api.lastNewLimit == 5);
      expect(api.lastNewLimit, 5);
    });
  });
}

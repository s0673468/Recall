import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import '../tool/fixtures/synthetic_recall_flow.dart';
import 'support/recall_test_harness.dart';

// Also run against the isolated checkpoint Controller: every batch removal must
// retain its daily-count receipts in native storage before dropping the outbox.
class _ReceiptGuard extends InMemorySharedPreferencesStore {
  _ReceiptGuard() : super.empty();

  bool refuseReceipts = false;
  int removed = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.recall_daily_reviews_v1' && refuseReceipts) {
      return false;
    }
    if (key == 'flutter.recall_outbox_v1') {
      final native = await getAll();
      final before = jsonDecode(native[key] as String? ?? '[]') as List;
      final after = jsonDecode(value as String) as List;
      final kept = {for (final row in after) row['client_id']};
      final dropped = before.where((row) => !kept.contains(row['client_id']));
      final receipts =
          jsonDecode(
                native['flutter.recall_daily_reviews_v1'] as String? ?? '[]',
              )
              as List;
      final durable = {
        for (final row in receipts)
          if (row['receipt'] == true) row['key'],
      };
      for (final row in dropped) {
        expect(durable, contains('event:${row['client_id']}'));
        removed++;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 24, 12);

  for (final refuse in [false, true]) {
    test('64-review drain preserves receipts; cache refusal=$refuse', () async {
      SharedPreferences.setMockInitialValues({});
      final native = _ReceiptGuard();
      SharedPreferencesStorePlatform.instance = native;
      final store = LocalReviewStore();
      for (var index = 0; index < 64; index++) {
        await store.enqueueReview({
          ...syntheticPendingReview(index),
          'card_id': 1,
          'last_review': now.toIso8601String(),
        });
      }
      final api = FakeRecallApi([testCard()]);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      native.refuseReceipts = refuse;
      if (refuse) {
        await expectLater(
          controller.syncPending(),
          throwsA(isA<LocalOutboxWriteException>()),
        );
        expect(await store.outbox(), hasLength(64));
        expect(native.removed, 0);
        native.refuseReceipts = false;
      }
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      expect(native.removed, 64);
      expect(api.server.reviewLog, hasLength(64));
      final restarted = LocalReviewStore();
      expect(
        await restarted.dailyReviewEvents(now: now, includePending: false),
        hasLength(64),
      );
    });
  }
}

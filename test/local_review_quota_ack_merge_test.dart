// A quota-rejected review must never be resurrected by a later acknowledgement.
// Synthetic native outcomes with invented fixture entries; no card content.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:health_anki_flutter/features/review/data/local_review_preferences.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

enum _Outcome { succeed, quotaRejectedBeforeCommit }

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.withData(const <String, Object>{});

  _Outcome outcome = _Outcome.succeed;
  String? affectedKey;
  int succeedGetAllBeforeFail = 0;
  bool failNextGetAll = false;

  // Full and keyed native reads share one fault gate, so the counters below
  // count every native read exactly once.
  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    if (succeedGetAllBeforeFail > 0) {
      succeedGetAllBeforeFail--;
      return super.getAllWithParameters(parameters);
    }
    if (failNextGetAll) {
      failNextGetAll = false;
      throw StateError('synthetic native read failure');
    }
    return super.getAllWithParameters(parameters);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (affectedKey != null &&
        key.contains(affectedKey!) &&
        outcome == _Outcome.quotaRejectedBeforeCommit) {
      throw const LocalPreferenceWriteNotCommitted();
    }
    return super.setValue(valueType, key, value);
  }
}

_Native _install() {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _Native();
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Map<String, dynamic> _review(String id) => {
  'client_id': id,
  'card_id': 42,
  'rating': 3,
};

Map<String, dynamic> _flag(String id) => {
  'client_id': id,
  'card_id': 42,
  'reason': 'synthetic bad card',
};

Future<List<Object?>> _reviewIds(LocalReviewStore store) async =>
    (await store.outbox()).map((e) => e['client_id']).toList();

Future<List<Object?>> _flagIds(LocalReviewStore store) async =>
    (await store.flagOutbox()).map((e) => e['client_id']).toList();

void main() {
  for (final flag in [false, true]) {
    final key = flag ? 'flag_outbox_v1' : 'recall_outbox_v1';
    test(
      'acknowledging another entry never persists a quota refusal: flag=$flag',
      () async {
        final native = _install();
        final store = LocalReviewStore();
        native.affectedKey = key;
        Future<int> append(String id) => flag
            ? store.enqueueFlag(_flag(id))
            : store.enqueueReview(_review(id));

        expect(await append('durable-a'), 1);
        native.outcome = _Outcome.quotaRejectedBeforeCommit;
        await expectLater(
          append('quota-b'),
          throwsA(isA<LocalPreferenceWriteNotCommitted>()),
        );
        // Only the durable entry is visible; the refusal admits no action.
        expect(flag ? await _flagIds(store) : await _reviewIds(store), [
          'durable-a',
        ]);
        // The rejected value was evicted from the shared cache.
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          isNot(contains('quota-b')),
        );

        // Acknowledge the durable entry with its exact stored payload. The
        // rejected review must not be merged into native truth in its place.
        native.outcome = _Outcome.succeed;
        final acked = flag
            ? await store.flagOutbox()
            : await store.outbox();
        final durable = acked.where((e) => e['client_id'] == 'durable-a');
        if (flag) {
          expect(await store.removeAcknowledgedFlags(durable), 0);
          expect(await _flagIds(store), isEmpty);
        } else {
          expect(await store.removeAcknowledgedReviews(durable), 0);
          expect(await _reviewIds(store), isEmpty);
        }
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          isNot(contains('quota-b')),
        );

        // A restart sees no resurrected refusal.
        SharedPreferences.resetStatic();
        final restarted = LocalReviewStore();
        expect(
          flag ? await _flagIds(restarted) : await _reviewIds(restarted),
          isEmpty,
        );

        // A fresh-ID retry for the same card submits exactly once.
        native.outcome = _Outcome.succeed;
        expect(await append('fresh-c'), 1);
        expect(flag ? await _flagIds(store) : await _reviewIds(store), [
          'fresh-c',
        ]);
        final pending = flag
            ? await store.flagOutbox()
            : await store.outbox();
        if (flag) {
          expect(await store.removeAcknowledgedFlags(pending), 0);
        } else {
          expect(await store.removeAcknowledgedReviews(pending), 0);
        }
        expect(flag ? await _flagIds(store) : await _reviewIds(store), isEmpty);
        await store.clear(requireEmptyOutboxes: true);
      },
    );

    test(
      'stale cache copy of a quota refusal is still excluded: flag=$flag',
      () async {
        final native = _install();
        final store = LocalReviewStore();
        native.affectedKey = key;
        Future<int> append(String id) => flag
            ? store.enqueueFlag(_flag(id))
            : store.enqueueReview(_review(id));

        expect(await append('durable-a'), 1);
        // Fail the post-refusal cache resync so the rejected value stays in
        // the shared cache; the acknowledgement merge must still exclude it.
        // The pre-write snapshot read must still succeed: only the reload fails.
        native
          ..outcome = _Outcome.quotaRejectedBeforeCommit
          ..succeedGetAllBeforeFail = 1
          ..failNextGetAll = true;
        await expectLater(
          append('quota-b'),
          throwsA(isA<LocalPreferenceWriteNotCommitted>()),
        );
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          contains('quota-b'),
        );

        native.outcome = _Outcome.succeed;
        final acked = flag
            ? await store.flagOutbox()
            : await store.outbox();
        final durable = acked.where((e) => e['client_id'] == 'durable-a');
        if (flag) {
          expect(await store.removeAcknowledgedFlags(durable), 0);
          expect(await _flagIds(store), isEmpty);
        } else {
          expect(await store.removeAcknowledgedReviews(durable), 0);
          expect(await _reviewIds(store), isEmpty);
        }
        // The tombstoned id is gone from durable truth even though the stale
        // cache copy existed at merge time.
        SharedPreferences.resetStatic();
        final restarted = LocalReviewStore();
        expect(
          flag ? await _flagIds(restarted) : await _reviewIds(restarted),
          isEmpty,
        );
        await store.clear(requireEmptyOutboxes: true);
      },
    );
  }
}

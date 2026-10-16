// Synthetic native outcomes for the durable study-action outboxes.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_preferences.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

enum _Outcome {
  succeed,
  refuse,
  throwBeforeCommit,
  quotaRejectedBeforeCommit,
  commitThenThrow,
  commitDrainThenThrow,
}

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.withData(const <String, Object>{});

  _Outcome outcome = _Outcome.succeed;
  String? affectedKey;
  String? refuseRemoveKey;
  String? throwRemoveAfterCommitKey;
  bool failReconciliationRead = false;
  bool _failNextRead = false;

  @override
  Future<Map<String, Object>> getAll() async {
    if (_failNextRead) {
      _failNextRead = false;
      throw StateError('synthetic native read failure');
    }
    return super.getAll();
  }

  @override
  Future<bool> remove(String key) async {
    if (throwRemoveAfterCommitKey != null &&
        key.contains(throwRemoveAfterCommitKey!)) {
      await super.remove(key);
      throw StateError('synthetic post-commit remove failure');
    }
    if (refuseRemoveKey != null && key.contains(refuseRemoveKey!)) {
      return false;
    }
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (affectedKey == null || !key.contains(affectedKey!)) {
      return super.setValue(valueType, key, value);
    }
    switch (outcome) {
      case _Outcome.succeed:
        return super.setValue(valueType, key, value);
      case _Outcome.refuse:
        return false;
      case _Outcome.throwBeforeCommit:
        _failNextRead = failReconciliationRead;
        throw StateError('synthetic pre-commit failure');
      case _Outcome.quotaRejectedBeforeCommit:
        throw const LocalPreferenceWriteNotCommitted();
      case _Outcome.commitThenThrow:
        await super.setValue(valueType, key, value);
        _failNextRead = failReconciliationRead;
        throw StateError('synthetic post-commit failure');
      case _Outcome.commitDrainThenThrow:
        await super.setValue(valueType, key, value);
        // An independent tab delivered and drained the just-committed list
        // before the producer's failure reconciliation could inspect it.
        await super.setValue('String', key, '[]');
        _failNextRead = failReconciliationRead;
        throw StateError('synthetic commit, external drain, then failure');
    }
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

Future<void> _appendNative(
  _Native native,
  String key,
  Map<String, dynamic> entry,
) async {
  final nativeKey = 'flutter.$key';
  final values = await native.getAll();
  final current = values[nativeKey] == null
      ? <Object?>[]
      : jsonDecode(values[nativeKey] as String) as List;
  native.affectedKey = null;
  expect(
    await native.setValue('String', nativeKey, jsonEncode([...current, entry])),
    isTrue,
  );
}

Future<List<Object?>> _reviewIds(LocalReviewStore store) async =>
    (await store.outbox()).map((e) => e['client_id']).toList();

Future<List<Object?>> _flagIds(LocalReviewStore store) async =>
    (await store.flagOutbox()).map((e) => e['client_id']).toList();

void main() {
  test('definitely refused review merges with another tab append', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'recall_outbox_v1';
    native.outcome = _Outcome.refuse;
    await expectLater(
      store.enqueueReview(_review('refused-a')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(await _reviewIds(store), isEmpty); // Unsaved actions cannot sync.

    native.outcome = _Outcome.succeed;
    await _appendNative(native, 'recall_outbox_v1', _review('other-tab'));
    expect(await store.enqueueReview(_review('later-b')), 3);
    SharedPreferences.resetStatic();
    expect(await _reviewIds(LocalReviewStore()), [
      'other-tab',
      'refused-a',
      'later-b',
    ]);
  });

  for (final flag in [false, true]) {
    test(
      'proven quota rejection admits no pending action: flag=$flag',
      () async {
        final native = _install();
        final store = LocalReviewStore();
        final key = flag ? 'flag_outbox_v1' : 'recall_outbox_v1';
        Future<int> append(String id) => flag
            ? store.enqueueFlag(_flag(id))
            : store.enqueueReview(_review(id));
        Future<List<Object?>> ids() =>
            flag ? _flagIds(store) : _reviewIds(store);
        native
          ..affectedKey = key
          ..outcome = _Outcome.quotaRejectedBeforeCommit;
        await expectLater(
          append('quota-rejected'),
          throwsA(isA<LocalPreferenceWriteNotCommitted>()),
        );
        expect(await ids(), isEmpty);
        // The legacy cache contains the rejected value; it is not durable truth.
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          contains('quota-rejected'),
        );
        native.outcome = _Outcome.succeed;
        expect(await append('fresh-click'), 1);
        expect(await ids(), ['fresh-click']);
        SharedPreferences.resetStatic();
        final restarted = LocalReviewStore();
        expect(flag ? await _flagIds(restarted) : await _reviewIds(restarted), [
          'fresh-click',
        ]);
        if (flag) {
          expect(await store.removeFirstFlag(1), 0);
        } else {
          expect(await store.removeFirst(1), 0);
        }
        await store.clear(requireEmptyOutboxes: true);
      },
    );

    test(
      'quota rejection preserves earlier pending actions: flag=$flag',
      () async {
        final native = _install();
        final store = LocalReviewStore();
        Future<int> append(String id) => flag
            ? store.enqueueFlag(_flag(id))
            : store.enqueueReview(_review(id));
        Future<List<Object?>> ids() =>
            flag ? _flagIds(store) : _reviewIds(store);
        native.affectedKey = flag ? 'flag_outbox_v1' : 'recall_outbox_v1';
        expect(await append('durable-first'), 1);
        native.outcome = _Outcome.refuse;
        await expectLater(
          append('earlier-retryable'),
          throwsA(isA<LocalOutboxWriteException>()),
        );
        native.outcome = _Outcome.quotaRejectedBeforeCommit;
        await expectLater(
          append('quota-rejected'),
          throwsA(isA<LocalPreferenceWriteNotCommitted>()),
        );
        expect(await ids(), ['durable-first']);
        final pending = await store
            .clear(requireEmptyOutboxes: true)
            .then<Object?>((_) => null, onError: (Object error) => error);
        expect(pending, isA<LocalOutboxNotEmptyException>());
        final error = pending as LocalOutboxNotEmptyException;
        expect(flag ? error.pendingFlags : error.pendingReviews, 2);
        native.outcome = _Outcome.succeed;
        expect(await append('later-accepted'), 3);
        expect(await ids(), [
          'durable-first',
          'earlier-retryable',
          'later-accepted',
        ]);
      },
    );
  }

  test(
    'retrying the same client id writes once and preserves attempt marker',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.refuse;
      await expectLater(
        store.enqueueReview(_review('same-id')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      native.outcome = _Outcome.succeed;

      expect(await store.enqueueReview(_review('same-id')), 1);
      expect(await store.markReviewAttempted('same-id'), isTrue);
      expect(await store.enqueueReview(_review('same-id')), 1);
      final durable = await store.outbox();
      expect(durable, hasLength(1));
      expect(durable.single['delivery_attempted'], isTrue);
    },
  );

  test('definitely refused flag merges with another tab append', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'flag_outbox_v1';
    native.outcome = _Outcome.refuse;
    await expectLater(
      store.enqueueFlag(_flag('refused-a')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(await _flagIds(store), isEmpty);

    native.outcome = _Outcome.succeed;
    await _appendNative(native, 'flag_outbox_v1', _flag('other-tab'));
    expect(await store.enqueueFlag(_flag('later-b')), 3);
    SharedPreferences.resetStatic();
    expect(await _flagIds(LocalReviewStore()), [
      'other-tab',
      'refused-a',
      'later-b',
    ]);
  });

  test(
    'unclassified throw stays uncertain and blocks later producer',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.throwBeforeCommit;
      await expectLater(
        store.enqueueReview(_review('unknown-a')),
        throwsA(isA<StateError>()),
      );
      expect(await _reviewIds(store), isEmpty);
      native.outcome = _Outcome.succeed;
      expect(
        await store.enqueueReview(_review('canceled'), canWrite: () => false),
        0,
      );

      await expectLater(
        store.enqueueReview(_review('later-b')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(await _reviewIds(store), isEmpty);
      expect((await store.removeEntry('unknown-a')).removed, isFalse);
      await expectLater(
        store.clear(requireEmptyOutboxes: true),
        throwsA(isA<LocalOutboxNotEmptyException>()),
      );
    },
  );

  test('failed reconciliation read keeps a thrown write uncertain', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'recall_outbox_v1';
    native.outcome = _Outcome.throwBeforeCommit;
    native.failReconciliationRead = true;
    await expectLater(
      store.enqueueReview(_review('unknown-a')),
      throwsA(isA<StateError>()),
    );
    native.outcome = _Outcome.succeed;

    await expectLater(
      store.enqueueReview(_review('later-b')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(await _reviewIds(store), isEmpty);
    await expectLater(
      store.clear(requireEmptyOutboxes: true),
      throwsA(isA<LocalOutboxNotEmptyException>()),
    );
  });

  test(
    'commit then external drain before reconciliation never replays',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.commitDrainThenThrow;
      await expectLater(
        store.enqueueReview(_review('already-sent')),
        throwsA(isA<StateError>()),
      );
      native.outcome = _Outcome.succeed;

      await expectLater(
        store.enqueueReview(_review('later')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(await _reviewIds(store), isEmpty);
      await expectLater(
        store.clear(requireEmptyOutboxes: true),
        throwsA(isA<LocalOutboxNotEmptyException>()),
      );
    },
  );

  test(
    'prior false append enters quarantine with a later unknown write',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.refuse;
      await expectLater(
        store.enqueueReview(_review('refused-a')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      native.outcome = _Outcome.commitDrainThenThrow;
      await expectLater(
        store.enqueueReview(_review('unknown-b')),
        throwsA(isA<StateError>()),
      );
      native.outcome = _Outcome.succeed;

      await expectLater(
        store.enqueueReview(_review('later-c')),
        throwsA(isA<LocalOutboxWriteException>()),
      );
      expect(await _reviewIds(store), isEmpty);
      final error = await store
          .clear(requireEmptyOutboxes: true)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<LocalOutboxNotEmptyException>());
      expect((error as LocalOutboxNotEmptyException).pendingReviews, 2);
    },
  );

  test(
    'native-visible uncertain id settles, then later append proceeds',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.commitThenThrow;
      await expectLater(
        store.enqueueReview(_review('committed-a')),
        throwsA(isA<StateError>()),
      );
      native.outcome = _Outcome.succeed;
      expect(await store.enqueueReview(_review('later-b')), 2);
      expect(await _reviewIds(store), ['committed-a', 'later-b']);
    },
  );

  test(
    'post-commit throw then review attempt and drain stays drained',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.commitThenThrow;
      await expectLater(
        store.enqueueReview(_review('sent-a')),
        throwsA(isA<StateError>()),
      );
      native.outcome = _Outcome.succeed;

      expect(await store.markReviewAttempted('sent-a'), isTrue);
      expect(await store.removeFirst(1), 0);
      expect(await store.enqueueReview(_review('later-b')), 1);
      expect(await _reviewIds(store), ['later-b']);
    },
  );

  test('post-commit throw then flag drain stays drained', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'flag_outbox_v1';
    native.outcome = _Outcome.commitThenThrow;
    await expectLater(
      store.enqueueFlag(_flag('sent-a')),
      throwsA(isA<StateError>()),
    );
    native.outcome = _Outcome.succeed;

    expect(await store.removeFirstFlag(1), 0);
    expect(await store.enqueueFlag(_flag('later-b')), 1);
    expect(await _flagIds(store), ['later-b']);
  });

  test('owner B proceeds while A is quarantined; A remains guarded', () async {
    final native = _install();
    final store = LocalReviewStore();
    await store.activateOwner('invented-owner-a');
    native.affectedKey = 'recall_outbox_v1:owner:';
    native.outcome = _Outcome.throwBeforeCommit;
    await expectLater(
      store.enqueueReview(_review('owner-a-unknown')),
      throwsA(isA<StateError>()),
    );
    native.outcome = _Outcome.succeed;

    await store.releaseOwner();
    await store.activateOwner('invented-owner-b');
    expect(await store.enqueueReview(_review('owner-b')), 1);
    expect(await _reviewIds(store), ['owner-b']);

    await store.releaseOwner();
    await store.activateOwner('invented-owner-a');
    await expectLater(
      store.enqueueReview(_review('owner-a-later')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    await expectLater(
      store.clear(requireEmptyOutboxes: true),
      throwsA(isA<LocalOutboxNotEmptyException>()),
    );
  });

  test('cancellation does not flush a definite failed append', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'recall_outbox_v1';
    native.outcome = _Outcome.refuse;
    await expectLater(
      store.enqueueReview(_review('refused-a')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    native.outcome = _Outcome.succeed;
    expect(
      await store.enqueueReview(_review('canceled'), canWrite: () => false),
      0,
    );
    expect(await _reviewIds(store), isEmpty);
    expect(await store.enqueueReview(_review('later-b')), 2);
  });

  test('refused clear cannot discard a definite failed append', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'recall_outbox_v1';
    native.outcome = _Outcome.refuse;
    await expectLater(
      store.enqueueReview(_review('refused-a')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    native.outcome = _Outcome.succeed;
    native.refuseRemoveKey = 'recall_outbox_v1';
    await expectLater(store.clear(), throwsA(isA<LocalOutboxWriteException>()));
    native.refuseRemoveKey = null;

    expect(await store.enqueueReview(_review('later-b')), 2);
    expect(await _reviewIds(store), ['refused-a', 'later-b']);
  });

  test('thrown clear quarantines an earlier definite failed append', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'recall_outbox_v1';
    native.outcome = _Outcome.refuse;
    await expectLater(
      store.enqueueReview(_review('refused-a')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    native.outcome = _Outcome.succeed;
    native.throwRemoveAfterCommitKey = 'recall_outbox_v1';
    await expectLater(store.clear(), throwsA(isA<StateError>()));
    native.throwRemoveAfterCommitKey = null;

    await expectLater(
      store.enqueueReview(_review('later-b')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    await expectLater(
      store.clear(requireEmptyOutboxes: true),
      throwsA(isA<LocalOutboxNotEmptyException>()),
    );
  });

  test('unknown flag also blocks same key without blocking reviews', () async {
    final native = _install();
    final store = LocalReviewStore();
    native.affectedKey = 'flag_outbox_v1';
    native.outcome = _Outcome.commitDrainThenThrow;
    await expectLater(
      store.enqueueFlag(_flag('flag-sent')),
      throwsA(isA<StateError>()),
    );
    native.outcome = _Outcome.succeed;
    expect(await store.removeFlagEntry('flag-sent'), isFalse);
    await expectLater(
      store.enqueueFlag(_flag('flag-later')),
      throwsA(isA<LocalOutboxWriteException>()),
    );
    expect(await _flagIds(store), isEmpty);
    await expectLater(
      store.clear(requireEmptyOutboxes: true),
      throwsA(isA<LocalOutboxNotEmptyException>()),
    );
    expect(await store.enqueueReview(_review('review-allowed')), 1);
  });

  test(
    'undo removes only its definite failed append and preserves the rest',
    () async {
      final native = _install();
      final store = LocalReviewStore();
      native.affectedKey = 'recall_outbox_v1';
      native.outcome = _Outcome.refuse;
      for (final id in ['undo-a', 'keep-b']) {
        await expectLater(
          store.enqueueReview(_review(id)),
          throwsA(isA<LocalOutboxWriteException>()),
        );
      }
      native.outcome = _Outcome.succeed;
      expect((await store.removeEntry('undo-a')).removed, isTrue);
      await expectLater(
        store.clear(requireEmptyOutboxes: true),
        throwsA(isA<LocalOutboxNotEmptyException>()),
      );
      expect(await store.enqueueReview(_review('later-c')), 2);
      SharedPreferences.resetStatic();
      expect(await _reviewIds(LocalReviewStore()), ['keep-b', 'later-c']);
    },
  );
}

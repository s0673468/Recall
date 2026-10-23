// Synthetic native preferences only; no device storage or network services.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

class _RecoveringPreferences extends InMemorySharedPreferencesStore {
  _RecoveringPreferences()
    : super.withData({
        'flutter.recall_outbox_v1':
            '[{"client_id":"synthetic-pending","card_id":1}]',
      });

  final failure = StateError('Synthetic preference initialization failure');
  var initializationReads = 0;
  var failuresRemaining = 1;

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    if (parameters.filter.allowList == null) {
      initializationReads++;
      if (failuresRemaining > 0) {
        failuresRemaining--;
        throw failure;
      }
    }
    return super.getAllWithParameters(parameters);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecoveringPreferences native;
  late LocalReviewStore store;
  setUp(() {
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    native = _RecoveringPreferences();
    SharedPreferencesStorePlatform.instance = native;
    store = LocalReviewStore();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    });
  });

  test(
    'outbox retries initialization and retains existing pending reviews',
    () async {
      await expectLater(store.outbox(), throwsA(same(native.failure)));

      expect(
        await store.enqueueReview({
          'client_id': 'synthetic-next',
          'card_id': 2,
        }),
        2,
      );
      expect((await store.outbox()).map((row) => row['client_id']), [
        'synthetic-pending',
        'synthetic-next',
      ]);
      expect(native.initializationReads, 2);
    },
  );

  test(
    'failed broad initialization does not poison later keyed reads',
    () async {
      await expectLater(store.clear(), throwsA(same(native.failure)));

      expect((await store.outbox()).single['client_id'], 'synthetic-pending');
      expect(native.initializationReads, 2);
    },
  );

  test(
    'blind progress writes retry initialization without losing the outbox',
    () async {
      const progress = CatchUpLocalState(
        mode: CatchUpMode.active,
        dayKey: '2026-10-23',
        completedToday: 3,
      );
      await expectLater(
        store.saveCatchUpState(progress),
        throwsA(same(native.failure)),
      );

      await store.saveCatchUpState(progress);
      expect(await store.loadCatchUpState(), progress);
      expect((await store.outbox()).single['client_id'], 'synthetic-pending');
      expect(native.initializationReads, 2);
    },
  );

  test(
    'repeated failures remain visible and concurrent retries share success',
    () async {
      native.failuresRemaining = 2;
      await expectLater(store.loadSnapshot(), throwsA(same(native.failure)));
      await expectLater(store.outbox(), throwsA(same(native.failure)));

      final results = await Future.wait([
        store.loadSnapshot(),
        store.loadSnapshot(),
        store.loadSnapshot(),
      ]);
      expect(results, everyElement(isNull));
      expect(native.initializationReads, 3);
      expect((await store.outbox()).single['client_id'], 'synthetic-pending');
      expect(native.initializationReads, 3);
    },
  );
}

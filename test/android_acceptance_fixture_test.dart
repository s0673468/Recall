import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/android_acceptance_fixture.dart';
import 'support/recall_acceptance_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 1, 1, 12);
  final event = <String, dynamic>{
    'client_id': 'invented-event-1',
    'card_id': 1,
    'guid': 'sanitized-guid-1',
    'rating': 3,
    'last_review': now.toIso8601String(),
    'due': now.add(const Duration(days: 1)).toIso8601String(),
    'state': 2,
  };

  Future<AndroidAcceptanceApi> create() async {
    final api = AndroidAcceptanceApi(
      preferences: await SharedPreferences.getInstance(),
      dataset: SanitizedRecallDataset.productionScale(now: now),
    );
    await api.restore();
    return api;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'invented journal deduplicates concurrent delivery and reconstruction',
    () async {
      final first = await create();
      expect(first.currentUser, isNull);
      await first.signIn(
        email: AndroidAcceptanceApi.email,
        password: 'invented-only',
      );
      expect(
        await Future.wait([first.applyReview(event), first.applyReview(event)]),
        [20001, 20001],
      );
      expect(first.reviewLog, hasLength(1));
      final restored = await create();
      expect(restored.currentUser, isNotNull);
      expect(await restored.applyReview(event), 20001);
      expect(restored.reviewLog, hasLength(1));
      expect(restored.appliedReviewCardIds, [1]);
      await expectLater(
        restored.applyReview({...event, 'card_id': 2}),
        throwsStateError,
      );
      expect(restored.reviewLog, hasLength(1));
    },
  );

  test(
    'offline state persists and failed delivery does not append a receipt',
    () async {
      final api = await create();
      await api.signIn(
        email: AndroidAcceptanceApi.email,
        password: 'invented-only',
      );
      await api.setOnline(false);
      await expectLater(api.applyReview(event), throwsStateError);
      expect(api.reviewLog, isEmpty);
      final restored = await create();
      expect(restored.online, isFalse);
      await restored.setOnline(true);
      expect(await restored.applyReview(event), 20001);
      await restored.signOut();
      expect((await create()).currentUser, isNull);
    },
  );

  test(
    'fixture rejects other accounts and reviews without stable event IDs',
    () async {
      final api = await create();
      await expectLater(
        api.signIn(email: 'other@example.invalid', password: 'invented-only'),
        throwsStateError,
      );
      await api.signIn(
        email: AndroidAcceptanceApi.email,
        password: 'invented-only',
      );
      await expectLater(
        api.applyReview({...event}..remove('client_id')),
        throwsStateError,
      );
      expect(api.reviewLog, isEmpty);
    },
  );
}

// Contract B (unsaved actions cannot sync): a rating or flag the device refused
// is never shown or sent. The study header says so, and the card stays
// answerable, so a redo is saved exactly once. Every value here is invented.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_preferences.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';

import 'support/recall_test_harness.dart';

final _day = DateTime.utc(2031, 1, 2, 12);

/// How the native store refuses a write: a plain `false`, or a proven quota
/// refusal that surfaces as [LocalPreferenceWriteNotCommitted].
enum _Refusal { plainFalse, quota }

class _Native extends InMemorySharedPreferencesStore {
  _Native() : super.empty();

  String? refusedKey;
  _Refusal refusal = _Refusal.plainFalse;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final pattern = refusedKey;
    if (pattern != null && key.contains(pattern)) {
      if (refusal == _Refusal.quota) {
        throw const LocalPreferenceWriteNotCommitted();
      }
      return false;
    }
    return super.setValue(valueType, key, value);
  }

  /// Persisted rows for one outbox base key, across owner scopes.
  Future<List<Map<String, dynamic>>> rows(String base) async {
    final values = await super.getAll();
    return [
      for (final entry in values.entries)
        if (entry.key.contains(base))
          for (final row in jsonDecode(entry.value as String) as List)
            Map<String, dynamic>.from(row as Map),
    ];
  }
}

/// The controller reports a refused save, then rethrows it for its callers.
final _refused = anyOf(
  isA<LocalOutboxWriteException>(),
  isA<LocalPreferenceWriteNotCommitted>(),
);

class _Fixture {
  _Fixture(this.native, this.store, this.controller);

  final _Native native;
  final LocalReviewStore store;
  final ReviewController controller;
}

User _user() => User(
  id: 'invented-refused-save-owner',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: _day.toIso8601String(),
);

Future<_Fixture> _fixture() async {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _Native();
  SharedPreferencesStorePlatform.instance = native;
  // Deliveries stay queued, so the outboxes are the only place a save can show.
  final api = FakeRecallApi([
    for (var id = 1; id <= 3; id++)
      testCard(id: id, front: 'Invented front $id', back: 'Invented back $id'),
  ])..user = _user()
    ..failApplyReview = true
    ..failApplyFlag = true;
  final store = LocalReviewStore();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
  );
  addTearDown(() {
    controller.dispose();
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  await store.activateOwner(api.currentUser!.id);
  await controller.load(keepReviewed: false);
  return _Fixture(native, store, controller);
}

/// An action unawaited by the controller may still be reading native state.
/// Drain both outboxes before the test restores the default platform store.
Future<void> _settle(LocalReviewStore store) async {
  await store.outbox();
  await store.flagOutbox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final refusal in _Refusal.values) {
    test(
      'a refused rating ($refusal) stays on its answer and a redo is saved once',
      () async {
        final f = await _fixture();
        final c = f.controller;
        final cardId = c.state.current!.id;
        c.flip();
        f.native
          ..refusedKey = 'recall_outbox_v1'
          ..refusal = refusal;

        await expectLater(c.rate(Rating.good), throwsA(_refused));

        expect(c.state.current?.id, cardId, reason: 'must not advance');
        expect(c.state.showBack, isTrue);
        expect(c.state.reviewedThisSession, 0);
        expect(c.flagNotice, ReviewController.saveRefusedNotice);
        expect(await f.store.outbox(), isEmpty);
        expect(await f.native.rows('recall_outbox_v1'), isEmpty);

        // The redo is the only event that may persist for this card.
        f.native.refusedKey = null;
        await c.rate(Rating.good);

        expect(c.state.reviewedThisSession, 1);
        expect(c.flagNotice, isNull);
        final rows = await f.native.rows('recall_outbox_v1');
        expect(rows.map((row) => row['card_id']), [cardId]);
        await _settle(f.store);
      },
    );

    test('a refused flag ($refusal) shows the notice and a redo is queued once', () async {
      final f = await _fixture();
      final c = f.controller;
      final cardId = c.state.current!.id;
      f.native
        ..refusedKey = 'flag_outbox_v1'
        ..refusal = refusal;

      await expectLater(c.flag('wrong'), throwsA(_refused));

      expect(c.flagNotice, ReviewController.saveRefusedNotice);
      expect(c.state.current?.id, cardId, reason: 'a flag never advances');
      expect(await f.store.flagOutbox(), isEmpty);
      expect(await f.native.rows('flag_outbox_v1'), isEmpty);

      f.native.refusedKey = null;
      await c.flag('wrong');

      expect(c.flagNotice, 'Flagged for the weekly review');
      final rows = await f.native.rows('flag_outbox_v1');
      expect(rows.map((row) => row['card_id']), [cardId]);
      await _settle(f.store);
    });
  }

  test('a refused one-tap hide leaves the card visible and says so', () async {
    final f = await _fixture();
    final c = f.controller;
    final cardId = c.state.current!.id;
    f.native.refusedKey = 'flag_outbox_v1';

    await expectLater(c.hideCurrent('dislike'), throwsA(_refused));

    expect(c.state.current?.id, cardId);
    expect(c.state.index, 0);
    expect(c.flagNotice, ReviewController.saveRefusedNotice);
    expect(c.rateInFlight, isFalse);
    expect(await f.store.flagOutbox(), isEmpty);
    await _settle(f.store);
  });

  testWidgets('the study header shows the refused-save notice on the answer', (
    tester,
  ) async {
    final f = await _fixture();
    final c = f.controller;
    f.native.refusedKey = 'recall_outbox_v1';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: Scaffold(body: StudyScreen(controller: c)),
      ),
    );
    await tester.tap(find.text('Show answer'));
    await tester.pump();

    // The real Good button: the refusal is absorbed by the gesture, not thrown.
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();

    expect(find.text(ReviewController.saveRefusedNotice), findsOneWidget);
    // The answer and its rating bar stay on screen for the redo.
    expect(find.byKey(const ValueKey('study_rating_bar')), findsOneWidget);
    // The inline notice fades on its own.
    await tester.pump(const Duration(seconds: 4));
    expect(c.flagNotice, isNull);
    await tester.pumpAndSettle();
    expect(find.text(ReviewController.saveRefusedNotice), findsNothing);
  });
}

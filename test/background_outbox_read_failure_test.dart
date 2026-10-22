import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

class _Store extends LocalReviewStore {
  bool failRead = false;
  bool failFlagRead = false;

  @override
  Future<List<Map<String, dynamic>>> outbox({String? ownerScope}) async {
    if (failRead) throw StateError('Invented temporary review read failure');
    return super.outbox(ownerScope: ownerScope);
  }

  @override
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) async {
    if (failFlagRead) throw StateError('Invented temporary flag read failure');
    return super.flagOutbox(ownerScope: ownerScope);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final action in ['rating', 'report', 'hide', 'load', 'keepGoing']) {
    test('$action background read failure stays queued and retries', () async {
      final api = FakeRecallApi(
        action == 'keepGoing' ? [] : [testCard(id: 1), testCard(id: 2)],
      );
      final store = _Store();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        haptics: const ReviewHaptics(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.syncPending();
      final unhandled = <Object>[];
      await runZonedGuarded(() async {
        if (action == 'keepGoing') {
          store.failRead = true;
          await controller.keepGoing().catchError((Object error) {
            unhandled.add(error);
          });
        } else if (action == 'rating') {
          store.failRead = true;
          controller.flip();
          await controller.rate(Rating.good);
        } else {
          store.failFlagRead = true;
          if (action == 'load') {
            await controller.refresh();
          } else if (action == 'report') {
            await controller.flag('wrong');
          } else {
            await controller.hideCurrent('dislike');
          }
        }
        // Let the fire-and-forget sender and its error handler settle.
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }, (error, _) => unhandled.add(error));
      store.failRead = false;
      store.failFlagRead = false;
      if (action == 'rating') {
        expect(await store.outbox(), hasLength(1));
        expect(controller.state.current?.id, 2);
      } else if (['report', 'hide'].contains(action)) {
        expect(await store.flagOutbox(), hasLength(1));
      }
      await controller.syncPending();
      expect(await store.outbox(), isEmpty);
      expect(await store.flagOutbox(), isEmpty);
      expect(controller.state.loading, isFalse);
      expect(api.applied.length, action == 'rating' ? 1 : 0);
      expect(api.flagged.length, ['report', 'hide'].contains(action) ? 1 : 0);
      expect(unhandled, isEmpty);
    });
  }
}

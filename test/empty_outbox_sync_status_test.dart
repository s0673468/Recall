import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_test_harness.dart';

// Two controllers, separate stores, one invented in-memory preferences backend.
// The peer models another app instance successfully delivering the shared event.
class _Sender extends FakeRecallApi {
  Object? failure;
  int sends = 0;

  _Sender() : super([]);

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    sends++;
    final error = failure;
    if (error != null) throw error;
    return 101;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final permanent in [false, true]) {
    test('empty outbox clears a stale badge after peer delivery: '
        'permanent=$permanent', () async {
      final api = _Sender()
        ..failure = permanent
            ? const PostgrestException(
                code: '23503',
                message: 'synthetic missing card',
              )
            : StateError('synthetic transport failure');
      final store = LocalReviewStore();
      await store.enqueueReview({
        'client_id': 'synthetic-shared-review',
        'card_id': 9,
        'rating': 3,
      });
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.syncPending();
      expect(controller.state.pendingSync, 1);
      expect(controller.state.syncErrors, permanent ? 1 : 0);
      final offlineBefore = controller.state.offline;
      final serverErrorBefore = controller.state.serverError;

      final peerStore = LocalReviewStore();
      final peerApi = _Sender();
      final peer = ReviewController(
        api: peerApi,
        engine: FsrsEngine(),
        store: peerStore,
      );
      addTearDown(peer.dispose);
      await peer.syncPending();
      expect(peerApi.sends, 1);
      expect(await store.outbox(), isEmpty);
      // This instance has not yet received its foreground/reconnect sync tick.
      expect(controller.state.pendingSync, 1);

      await controller.syncPending();

      expect(controller.state.pendingSync, 0);
      expect(controller.state.syncErrors, 0);
      expect(api.sends, 1); // Empty storage never causes another delivery.
      // An empty local queue says nothing about this instance's connection.
      expect(controller.state.offline, offlineBefore);
      expect(controller.state.serverError, serverErrorBefore);
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.syncPending();
      expect(notifications, 0);
    });
  }
}

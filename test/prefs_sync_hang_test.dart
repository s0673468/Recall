import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'support/recall_test_harness.dart';

class _StalledPrefsApi extends FakeRecallApi {
  final bool stallSave;
  final gate = Completer<void>();
  int fetches = 0;
  int saves = 0;

  _StalledPrefsApi({required this.stallSave}) : super([testCard()]) {
    user = User(
      id: 'synthetic-owner',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    fetches++;
    if (!stallSave) await gate.future;
    return null;
  }

  @override
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    saves++;
    if (stallSave) await gate.future;
    await super.saveRecallPrefs(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final stallSave in [false, true]) {
    test('a stalled prefs ${stallSave ? 'write' : 'read'} cannot block '
        'the next reconnect review retry', () async {
      final api = _StalledPrefsApi(stallSave: stallSave);
      final pendingKey = RecallPrefsController.pendingKeyForOwner(api.user!.id);
      SharedPreferences.setMockInitialValues({
        if (stallSave) pendingKey: jsonEncode(const RecallPrefs().toJson()),
      });
      final prefs = RecallPrefsController(api: api);
      addTearDown(prefs.dispose);
      addTearDown(() {
        if (!api.gate.isCompleted) api.gate.complete();
      });
      await prefs.activateOwner(api.user!.id);
      final store = LocalReviewStore();
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        prefs: prefs,
        reviewSendTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(controller.dispose);
      await controller.load();

      api.failApplyReview = true;
      controller.flip();
      await controller.rate(Rating.good);
      final failed = await controller.syncPendingInBackground().timeout(
        const Duration(seconds: 3),
      );
      expect(failed.pending, 1);
      expect(api.gate.isCompleted, isFalse);

      // Native reconnect and foreground sync may try again while the old
      // preference transport is still occupied. Reviews must still drain.
      api.failApplyReview = false;
      final retried = await controller.syncPendingInBackground().timeout(
        const Duration(seconds: 3),
      );
      expect(retried.delivered, 1);
      expect(retried.pending, 0);
      expect(await store.outbox(), isEmpty);
      expect(api.applied, hasLength(1));

      // Repeated wake signals share at most one follow-up. In particular,
      // timed-out callers must not leave an unbounded chain of cloud reads.
      final queued = prefs.syncOwner();
      for (var i = 0; i < 100; i++) {
        expect(identical(prefs.syncOwner(), queued), isTrue);
      }
      expect(stallSave ? api.saves : api.fetches, 1);
      api.gate.complete();
      await queued;
      expect(api.fetches, stallSave ? 1 : 2);
      expect(api.saves, stallSave ? 1 : 0);
      final storage = await SharedPreferences.getInstance();
      expect(storage.containsKey(pendingKey), isFalse);
    });
  }
}

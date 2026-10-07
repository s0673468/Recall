import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/app/recall_dependencies.dart';
import 'package:health_anki_flutter/core/background/background_sync_coordinator.dart';
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

import 'recall_acceptance_fixture.dart';

/// An invented backend journal, not evidence of production RPC correctness.
/// Native SharedPreferences keeps this journal and the real client outbox across
/// process death. No production configuration or secure session is loaded.
class AndroidAcceptanceApi extends SanitizedRecallApi {
  static const journalKey = 'android_acceptance_review_log_v1';
  static const offlineKey = 'android_acceptance_offline_v1';
  static const signedInKey = 'android_acceptance_signed_in_v1';
  static const email = 'learner@example.invalid';
  final SharedPreferences preferences;
  final List<Map<String, dynamic>> _journal = [];
  Future<void> _tail = Future<void>.value();

  AndroidAcceptanceApi({required this.preferences, required super.dataset})
    : super(scenario: AcceptanceScenario.rich);

  List<Map<String, dynamic>> get reviewLog =>
      List.unmodifiable(_journal.map(Map<String, dynamic>.unmodifiable));

  Future<void> restore() async {
    final raw = preferences.getString(journalKey);
    if (raw != null) {
      final rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final row in rows) {
        if (row['owner'] != currentUser!.id) {
          throw StateError('Unexpected owner in invented backend journal');
        }
        await super.applyReview(Map<String, dynamic>.from(row['entry'] as Map));
        _journal.add(row);
      }
    }
    online = !(preferences.getBool(offlineKey) ?? false);
    if (!(preferences.getBool(signedInKey) ?? false)) await super.signOut();
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (email != AndroidAcceptanceApi.email || password != 'invented-only') {
      throw StateError('Use the documented invented acceptance account');
    }
    if (!await preferences.setBool(signedInKey, true)) {
      throw StateError('Could not persist invented sign-in');
    }
    await super.signIn(email: email, password: password);
  }

  @override
  Future<void> signOut() async {
    if (!await preferences.setBool(signedInKey, false)) {
      throw StateError('Could not persist invented sign-out');
    }
    await super.signOut();
  }

  Future<void> setOnline(bool value) async {
    if (!await preferences.setBool(offlineKey, !value)) {
      throw StateError('Could not persist invented backend connectivity');
    }
    online = value;
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) {
    final result = _tail.then((_) async {
      if (!online) throw StateError('Invented backend is offline');
      final owner = currentUser?.id;
      if (owner == null) throw StateError('Invented account is signed out');
      final event = entry['client_id'];
      if (event is! String || event.isEmpty) {
        throw StateError(
          'Native acceptance requires a durable client event id',
        );
      }
      for (final row in _journal) {
        if (row['owner'] == owner && row['event'] == event) {
          final original = row['entry'] as Map;
          if (original['card_id'] != entry['card_id'] ||
              original['rating'] != entry['rating'] ||
              original['last_review'] != entry['last_review']) {
            throw StateError(
              'Conflicting payload for an invented review event',
            );
          }
          return row['id'] as int;
        }
      }
      final row = <String, dynamic>{
        'id': 20001 + _journal.length,
        'owner': owner,
        'event': event,
        'entry': Map<String, dynamic>.from(entry),
      };
      // Commit the invented server receipt before acknowledging the client.
      if (!await preferences.setString(
        journalKey,
        jsonEncode([..._journal, row]),
      )) {
        throw StateError('Could not persist invented review log');
      }
      _journal.add(row);
      await super.applyReview(entry);
      return row['id'] as int;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Uses real Android preferences and platform channels in a separate test app.
Future<RecallDependencies> createAndroidAcceptanceDependencies() async {
  final preferences = await SharedPreferences.getInstance();
  final api = AndroidAcceptanceApi(
    preferences: preferences,
    dataset: SanitizedRecallDataset.productionScale(),
  );
  await api.restore();
  final store = LocalReviewStore();
  final prefs = RecallPrefsController(api: api);
  final reminder = StudyReminderController();
  final owner = api.currentUser?.id;
  if (owner != null) {
    await store.activateOwner(owner);
    await prefs.activateOwner(owner);
  }
  await reminder.initialize(ownerId: owner);
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(desiredRetention: RecallPrefs.defaultRetention),
    store: store,
    prefs: prefs,
    beforeSessionLoad: () async {
      final user = api.currentUser;
      if (user != null) {
        await store.activateOwner(user.id);
        await prefs.activateOwner(user.id);
      }
    },
    afterSignIn: () async {
      final user = api.currentUser;
      if (user != null) await reminder.activateOwner(user.id);
    },
    afterSignOut: () async {
      await reminder.releaseOwner();
      await prefs.releaseOwner();
      await store.releaseOwner();
    },
  );
  await controller.initialize();
  final background = BackgroundSyncCoordinator(
    platform: const MethodChannelBackgroundSyncPlatform(),
    sync: controller.syncPendingInBackground,
  );
  await background.start();
  return RecallDependencies(
    reviewController: controller,
    api: api,
    recallPrefs: prefs,
    backgroundSync: background,
    studyReminder: reminder,
  );
}

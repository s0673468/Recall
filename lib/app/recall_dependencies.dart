import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/background/background_sync_coordinator.dart';
import '../core/config/recall_config.dart';
import '../features/auth/data/secure_session_storage.dart';
import '../features/reminders/application/study_reminder_controller.dart';
import '../features/review/application/fsrs_engine.dart';
import '../features/review/application/review_controller.dart';
import '../features/review/data/local_review_store.dart';
import '../features/review/data/recall_api.dart';
import '../features/settings/application/recall_prefs_controller.dart';
import '../features/settings/domain/recall_prefs.dart';

/// Boots Supabase and wires the review feature.
class RecallDependencies {
  final ReviewController reviewController;
  final RecallApi api;
  final RecallPrefsController recallPrefs;
  final BackgroundSyncCoordinator backgroundSync;
  final StudyReminderController studyReminder;

  const RecallDependencies({
    required this.reviewController,
    required this.api,
    required this.recallPrefs,
    required this.backgroundSync,
    required this.studyReminder,
  });

  static Future<RecallDependencies> create() async {
    final config = await RecallConfig.load();
    if (!config.isConfigured) {
      throw const RecallConfigException();
    }

    final secureSessionStorage =
        supportsRecallSecureSession(
          isWeb: kIsWeb,
          targetPlatform: defaultTargetPlatform,
        )
        ? SecureRecallSupabaseLocalStorage.forSupabaseUrl(config.url)
        : null;
    final client = await _client(
      config,
      secureSessionStorage: secureSessionStorage,
    );

    final api = RecallApi(
      client,
      persistSession: secureSessionStorage?.persistSessionStrict,
      removePersistedSession:
          secureSessionStorage?.removePersistedSessionStrict,
    );
    final engine = FsrsEngine(desiredRetention: RecallPrefs.defaultRetention);
    final prefs = RecallPrefsController(api: api);
    final studyReminder = StudyReminderController();
    await studyReminder.initialize(ownerId: api.currentUser?.id);
    // The controller subscribes to auth changes in its constructor and loads the
    // queue once there's a session — so it must exist before we (maybe) sign in.
    final controller = ReviewController(
      api: api,
      engine: engine,
      store: LocalReviewStore(),
      prefs: prefs,
      afterSignOut: studyReminder.releaseOwner,
      afterSignIn: () async {
        final owner = api.currentUser;
        if (owner != null) await studyReminder.activateOwner(owner.id);
      },
    );
    final backgroundSync = BackgroundSyncCoordinator(
      platform: const MethodChannelBackgroundSyncPlatform(),
      sync: controller.syncPendingInBackground,
    );
    // Hydrate prefs (local mirror + cloud) before the shell mounts so the first
    // queue load already reflects the user's new-limit / order / retention.
    await prefs.load();
    await backgroundSync.start();

    return RecallDependencies(
      reviewController: controller,
      api: api,
      recallPrefs: prefs,
      backgroundSync: backgroundSync,
      studyReminder: studyReminder,
    );
  }

  static Future<SupabaseClient> _client(
    RecallConfig config, {
    SecureRecallSupabaseLocalStorage? secureSessionStorage,
  }) async {
    try {
      return Supabase.instance.client;
    } catch (_) {
      await Supabase.initialize(
        url: config.url,
        publishableKey: config.anonKey,
        authOptions: FlutterAuthClientOptions(
          localStorage: secureSessionStorage,
        ),
      );
      return Supabase.instance.client;
    }
  }

  void dispose() {
    reviewController.dispose();
    recallPrefs.dispose();
    studyReminder.dispose();
  }
}

class RecallConfigException implements Exception {
  const RecallConfigException();
  @override
  String toString() =>
      'Supabase config missing — pass SUPABASE_URL and SUPABASE_ANON_KEY '
      'with --dart-define-from-file.';
}

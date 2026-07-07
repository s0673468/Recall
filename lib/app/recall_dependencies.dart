import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/recall_config.dart';
import '../features/auth/application/biometric_sign_in_service.dart';
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
  final BiometricSignInService biometricSignIn;
  final RecallPrefsController recallPrefs;

  const RecallDependencies({
    required this.reviewController,
    required this.api,
    required this.biometricSignIn,
    required this.recallPrefs,
  });

  static Future<RecallDependencies> create() async {
    final config = await RecallConfig.load();
    if (!config.isConfigured) {
      throw const RecallConfigException();
    }

    final client = await _client(config);

    final api = RecallApi(client);
    final engine = FsrsEngine(desiredRetention: RecallPrefs.defaultRetention);
    final biometricSignIn = BiometricSignInService();
    final prefs = RecallPrefsController(api: api);
    // The controller subscribes to auth changes in its constructor and loads the
    // queue once there's a session — so it must exist before we (maybe) sign in.
    final controller = ReviewController(
      api: api,
      engine: engine,
      store: LocalReviewStore(),
      prefs: prefs,
      rememberCredentials: biometricSignIn.saveCredentials,
      forgetCredentials: biometricSignIn.clearCredentials,
    );
    // Hydrate prefs (local mirror + cloud) before the shell mounts so the first
    // queue load already reflects the user's new-limit / order / retention.
    await prefs.load();

    return RecallDependencies(
      reviewController: controller,
      api: api,
      biometricSignIn: biometricSignIn,
      recallPrefs: prefs,
    );
  }

  static Future<SupabaseClient> _client(RecallConfig config) async {
    try {
      return Supabase.instance.client;
    } catch (_) {
      await Supabase.initialize(
        url: config.url,
        publishableKey: config.anonKey,
      );
      return Supabase.instance.client;
    }
  }

  void dispose() {
    reviewController.dispose();
    recallPrefs.dispose();
  }
}

class RecallConfigException implements Exception {
  const RecallConfigException();
  @override
  String toString() =>
      'Supabase config missing — pass SUPABASE_URL and SUPABASE_ANON_KEY '
      'with --dart-define-from-file.';
}

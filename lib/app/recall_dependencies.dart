import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/recall_config.dart';
import '../features/auth/application/biometric_sign_in_service.dart';
import '../features/review/application/fsrs_engine.dart';
import '../features/review/application/review_controller.dart';
import '../features/review/data/local_review_store.dart';
import '../features/review/data/recall_api.dart';

/// Boots Supabase and wires the review feature.
class RecallDependencies {
  final ReviewController reviewController;
  final RecallApi api;
  final BiometricSignInService biometricSignIn;

  const RecallDependencies({
    required this.reviewController,
    required this.api,
    required this.biometricSignIn,
  });

  static Future<RecallDependencies> create() async {
    final config = await RecallConfig.load();
    if (!config.isConfigured) {
      throw const RecallConfigException();
    }

    final client = await _client(config);

    final api = RecallApi(client);
    final engine = FsrsEngine(desiredRetention: 0.9);
    final biometricSignIn = BiometricSignInService();
    // The controller subscribes to auth changes in its constructor and loads the
    // queue once there's a session — so it must exist before we (maybe) sign in.
    final controller = ReviewController(
      api: api,
      engine: engine,
      store: LocalReviewStore(),
      rememberCredentials: biometricSignIn.saveCredentials,
      forgetCredentials: biometricSignIn.clearCredentials,
    );

    return RecallDependencies(
      reviewController: controller,
      api: api,
      biometricSignIn: biometricSignIn,
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

  void dispose() => reviewController.dispose();
}

class RecallConfigException implements Exception {
  const RecallConfigException();
  @override
  String toString() =>
      'Supabase config missing — pass SUPABASE_URL and SUPABASE_ANON_KEY '
      'with --dart-define-from-file.';
}

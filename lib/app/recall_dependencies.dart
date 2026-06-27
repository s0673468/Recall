import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/recall_config.dart';
import '../features/review/application/fsrs_engine.dart';
import '../features/review/application/review_controller.dart';
import '../features/review/data/local_review_store.dart';
import '../features/review/data/recall_api.dart';

/// Boots Supabase and wires the review feature.
class RecallDependencies {
  final ReviewController reviewController;
  final RecallApi api;

  const RecallDependencies({required this.reviewController, required this.api});

  static Future<RecallDependencies> create() async {
    final config = await RecallConfig.load();
    if (!config.isConfigured) {
      throw const RecallConfigException();
    }

    final client = await _client(config);

    final api = RecallApi(client);
    final engine = FsrsEngine(desiredRetention: 0.9);
    // The controller subscribes to auth changes in its constructor and loads the
    // queue once there's a session — so it must exist before we (maybe) sign in.
    final controller = ReviewController(
      api: api,
      engine: engine,
      store: LocalReviewStore(),
    );

    return RecallDependencies(reviewController: controller, api: api);
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

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Connection + auto-login config for Recall.
///
/// Single-user personal app: the dedicated account's credentials are bundled so
/// the app signs in silently on launch (no login screen). RLS still scopes every
/// row to this one user. Provide via --dart-define or config/supabase.local.json.
class RecallConfig {
  final String url;
  final String anonKey;
  final String email;
  final String password;

  const RecallConfig({
    required this.url,
    required this.anonKey,
    required this.email,
    required this.password,
  });

  bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
  bool get canAutoLogin => email.isNotEmpty && password.isNotEmpty;

  static Future<RecallConfig> load() async {
    const envUrl = String.fromEnvironment('SUPABASE_URL');
    const envKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    const envEmail = String.fromEnvironment('RECALL_EMAIL');
    const envPass = String.fromEnvironment('RECALL_PASSWORD');

    if (envUrl.isNotEmpty && envKey.isNotEmpty) {
      return const RecallConfig(
        url: envUrl,
        anonKey: envKey,
        email: envEmail,
        password: envPass,
      );
    }

    try {
      final jsonStr = await rootBundle.loadString('config/supabase.local.json');
      final config = jsonDecode(jsonStr) as Map<String, dynamic>;
      return RecallConfig(
        url: (config['SUPABASE_URL'] as String?) ?? '',
        anonKey: (config['SUPABASE_ANON_KEY'] as String?) ?? '',
        email: (config['RECALL_EMAIL'] as String?) ?? '',
        password: (config['RECALL_PASSWORD'] as String?) ?? '',
      );
    } catch (_) {
      return const RecallConfig(url: '', anonKey: '', email: '', password: '');
    }
  }
}

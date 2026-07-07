/// Connection config for Recall.
///
/// The generated app must not contain account credentials. Provide only the
/// Supabase URL and public anon key via dart defines, then sign in through the
/// login screen.
class RecallConfig {
  final String url;
  final String anonKey;

  const RecallConfig({required this.url, required this.anonKey});

  bool get isConfigured =>
      url.isNotEmpty &&
      anonKey.isNotEmpty &&
      !_isPlaceholder(url) &&
      !_isPlaceholder(anonKey);

  static bool _isPlaceholder(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('your_project') ||
        normalized.contains('your-project') ||
        normalized.contains('your-anon') ||
        normalized.contains('your_anon');
  }

  static Future<RecallConfig> load() async {
    const envUrl = String.fromEnvironment('SUPABASE_URL');
    const envKey = String.fromEnvironment('SUPABASE_ANON_KEY');

    if (envUrl.isNotEmpty && envKey.isNotEmpty) {
      return const RecallConfig(url: envUrl, anonKey: envKey);
    }

    return const RecallConfig(url: '', anonKey: '');
  }
}

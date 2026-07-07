import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/core/config/recall_config.dart';

void main() {
  test('placeholder Supabase config is not treated as configured', () {
    const config = RecallConfig(
      url: 'https://YOUR_PROJECT.supabase.co',
      anonKey: 'your-anon-or-publishable-key',
    );

    expect(config.isConfigured, isFalse);
  });

  test('real-looking Supabase config is treated as configured', () {
    const config = RecallConfig(
      url: 'https://example.supabase.co',
      anonKey: 'sb_publishable_example',
    );

    expect(config.isConfigured, isTrue);
  });
}

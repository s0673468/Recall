import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/auth/data/secure_session_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SessionSecretStore {
  final values = <String, String>{};
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('delete failed');
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    values[key] = value;
  }
}

class _MemoryLegacyCredentialStore implements LegacyCredentialStore {
  final values = <String, String>{};
  final deleteCalls = <String>[];
  bool retainAfterDelete = false;
  String? failDeleteKey;

  @override
  Future<void> delete(String key) async {
    deleteCalls.add(key);
    if (key == failDeleteKey) throw StateError('delete failed for $key');
    if (!retainAfterDelete) values.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('moves the legacy Supabase session into secure storage', () async {
    const legacyKey = 'sb-recall-auth-token';
    const secureKey = 'recall.secure_auth_token.recall';
    const session = '{"refresh_token":"secret"}';
    SharedPreferences.setMockInitialValues({legacyKey: session});
    final secrets = _MemorySecretStore();
    final storage = SecureRecallSupabaseLocalStorage(
      secretStore: secrets,
      legacyCredentialStore: _MemoryLegacyCredentialStore(),
      secureKey: secureKey,
      legacyPreferencesKey: legacyKey,
    );

    await storage.initialize();

    expect(await storage.hasAccessToken(), isTrue);
    expect(await storage.accessToken(), session);
    expect(secrets.values[secureKey], session);
    expect(
      (await SharedPreferences.getInstance()).containsKey(legacyKey),
      isFalse,
    );
  });

  test('a failed secure migration leaves the legacy session intact', () async {
    const legacyKey = 'sb-recall-auth-token';
    SharedPreferences.setMockInitialValues({legacyKey: 'legacy-session'});
    final storage = SecureRecallSupabaseLocalStorage(
      secretStore: _MemorySecretStore()..failWrites = true,
      legacyCredentialStore: _MemoryLegacyCredentialStore(),
      secureKey: 'secure-key',
      legacyPreferencesKey: legacyKey,
    );
    await storage.initialize();

    await expectLater(storage.accessToken(), throwsStateError);

    expect(
      (await SharedPreferences.getInstance()).getString(legacyKey),
      'legacy-session',
    );
  });

  test('a verified secure session wins and erases the legacy copy', () async {
    const legacyKey = 'sb-recall-auth-token';
    SharedPreferences.setMockInitialValues({legacyKey: 'legacy-session'});
    final secrets = _MemorySecretStore()
      ..values['secure-key'] = 'secure-session';
    final storage = SecureRecallSupabaseLocalStorage(
      secretStore: secrets,
      legacyCredentialStore: _MemoryLegacyCredentialStore(),
      secureKey: 'secure-key',
      legacyPreferencesKey: legacyKey,
    );
    await storage.initialize();

    expect(await storage.accessToken(), 'secure-session');
    expect(
      (await SharedPreferences.getInstance()).containsKey(legacyKey),
      isFalse,
    );
  });

  test(
    'sign-out removes the preference even if secure deletion fails',
    () async {
      const legacyKey = 'sb-recall-auth-token';
      SharedPreferences.setMockInitialValues({legacyKey: 'legacy-session'});
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: _MemorySecretStore()..failDeletes = true,
        legacyCredentialStore: _MemoryLegacyCredentialStore(),
        secureKey: 'secure-key',
        legacyPreferencesKey: legacyKey,
      );
      await storage.initialize();

      await expectLater(
        storage.removePersistedSessionStrict(),
        throwsStateError,
      );

      expect(
        (await SharedPreferences.getInstance()).containsKey(legacyKey),
        isFalse,
      );
    },
  );

  test('framework persistence callback contains secure write errors', () async {
    final storage = SecureRecallSupabaseLocalStorage(
      secretStore: _MemorySecretStore()..failWrites = true,
      legacyCredentialStore: _MemoryLegacyCredentialStore(),
      secureKey: 'secure-key',
      legacyPreferencesKey: 'legacy-key',
    );

    await expectLater(storage.persistSession('session'), completes);
    await expectLater(
      storage.persistSessionStrict('session'),
      throwsStateError,
    );
  });

  test('framework deletion callback contains secure delete errors', () async {
    final storage = SecureRecallSupabaseLocalStorage(
      secretStore: _MemorySecretStore()..failDeletes = true,
      legacyCredentialStore: _MemoryLegacyCredentialStore(),
      secureKey: 'secure-key',
      legacyPreferencesKey: 'legacy-key',
    );

    await expectLater(storage.removePersistedSession(), completes);
    await expectLater(storage.removePersistedSessionStrict(), throwsStateError);
  });

  test('startup erases the old email and password Keychain entries', () async {
    final credentials = _MemoryLegacyCredentialStore()
      ..values['recall.auth.email'] = 'person@example.com'
      ..values['recall.auth.password'] = 'do-not-keep-this';
    final storage = SecureRecallSupabaseLocalStorage(
      secretStore: _MemorySecretStore(),
      legacyCredentialStore: credentials,
      secureKey: 'secure-key',
      legacyPreferencesKey: 'legacy-key',
    );

    await storage.initialize();

    expect(credentials.values, isEmpty);
  });

  test(
    'startup fails closed when legacy password deletion is not verified',
    () async {
      final credentials = _MemoryLegacyCredentialStore()
        ..retainAfterDelete = true
        ..values['recall.auth.password'] = 'still-present';
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: _MemorySecretStore(),
        legacyCredentialStore: credentials,
        secureKey: 'secure-key',
        legacyPreferencesKey: 'legacy-key',
      );

      await expectLater(storage.initialize(), throwsStateError);
    },
  );

  test('derives stable secure and legacy keys from a Supabase URL', () {
    final keys = recallSessionKeysForUrl('https://abc123.supabase.co');

    expect(keys.secureKey, 'recall.secure_auth_token.abc123');
    expect(keys.legacyPreferencesKey, 'sb-abc123-auth-token');
  });

  test(
    'legacy cleanup attempts both keys when the first deletion fails',
    () async {
      final credentials = _MemoryLegacyCredentialStore()
        ..failDeleteKey = 'recall.auth.email';
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: _MemorySecretStore(),
        legacyCredentialStore: credentials,
        secureKey: 'secure-key',
        legacyPreferencesKey: 'legacy-key',
      );

      await expectLater(storage.initialize(), throwsStateError);

      expect(credentials.deleteCalls, [
        'recall.auth.email',
        'recall.auth.password',
      ]);
    },
  );
}

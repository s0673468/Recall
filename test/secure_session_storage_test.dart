import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/auth/data/secure_session_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SessionSecretStore {
  final values = <String, String>{};
  bool failWrites = false;
  bool failDeletes = false;
  bool failReads = false;
  bool retainAfterDelete = false;
  String? readAfterWriteOverride;
  int writeCalls = 0;

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('delete failed');
    if (!retainAfterDelete) values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('read failed');
    if (writeCalls > 0 && readAfterWriteOverride != null) {
      return readAfterWriteOverride;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    writeCalls++;
    values[key] = value;
  }
}

class _MemoryLegacyCredentialStore implements LegacyCredentialStore {
  final values = <String, String>{};
  final deleteCalls = <String>[];
  bool retainAfterDelete = false;
  String? failDeleteKey;
  String? failContainsKey;

  @override
  Future<void> delete(String key) async {
    deleteCalls.add(key);
    if (key == failDeleteKey) throw StateError('delete failed for $key');
    if (!retainAfterDelete) values.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async {
    if (key == failContainsKey) throw StateError('contains failed for $key');
    return values.containsKey(key);
  }
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

  test(
    'native secure read error refuses legacy migration without erasing it',
    () async {
      const legacyKey = 'sb-invented-auth-token';
      SharedPreferences.setMockInitialValues({legacyKey: 'invented-session'});
      final secrets = _MemorySecretStore()..failReads = true;
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: secrets,
        legacyCredentialStore: _MemoryLegacyCredentialStore(),
        secureKey: 'invented-secure-key',
        legacyPreferencesKey: legacyKey,
      );

      await expectLater(storage.accessToken(), throwsStateError);

      expect(secrets.values, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(legacyKey),
        'invented-session',
      );
    },
  );

  test(
    'unverified secure write refuses migration and retains legacy session',
    () async {
      const legacyKey = 'sb-invented-auth-token';
      SharedPreferences.setMockInitialValues({legacyKey: 'invented-session'});
      final secrets = _MemorySecretStore()
        ..readAfterWriteOverride = 'stale-readback';
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: secrets,
        legacyCredentialStore: _MemoryLegacyCredentialStore(),
        secureKey: 'invented-secure-key',
        legacyPreferencesKey: legacyKey,
      );

      await expectLater(storage.accessToken(), throwsStateError);

      expect(secrets.writeCalls, 1);
      expect(secrets.values['invented-secure-key'], 'invented-session');
      expect(
        (await SharedPreferences.getInstance()).getString(legacyKey),
        'invented-session',
      );
    },
  );

  test(
    'malformed legacy preference type fails closed without a secure write',
    () async {
      const legacyKey = 'sb-invented-auth-token';
      SharedPreferences.setMockInitialValues({legacyKey: 42});
      final secrets = _MemorySecretStore();
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: secrets,
        legacyCredentialStore: _MemoryLegacyCredentialStore(),
        secureKey: 'invented-secure-key',
        legacyPreferencesKey: legacyKey,
      );

      await expectLater(storage.accessToken(), throwsA(isA<TypeError>()));

      expect(secrets.values, isEmpty);
      expect((await SharedPreferences.getInstance()).getInt(legacyKey), 42);
    },
  );

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

  test(
    'strict deletion rejects a native no-op and still clears legacy state',
    () async {
      const legacyKey = 'sb-invented-auth-token';
      SharedPreferences.setMockInitialValues({legacyKey: 'invented-legacy'});
      final secrets = _MemorySecretStore()
        ..values['invented-secure-key'] = 'invented-secure'
        ..retainAfterDelete = true;
      final credentials = _MemoryLegacyCredentialStore();
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: secrets,
        legacyCredentialStore: credentials,
        secureKey: 'invented-secure-key',
        legacyPreferencesKey: legacyKey,
      );

      await expectLater(
        storage.removePersistedSessionStrict(),
        throwsStateError,
      );

      expect(secrets.values['invented-secure-key'], 'invented-secure');
      expect(
        (await SharedPreferences.getInstance()).containsKey(legacyKey),
        isFalse,
      );
      expect(credentials.deleteCalls, [
        LegacyRecallCredentialCleaner.emailKey,
        LegacyRecallCredentialCleaner.passwordKey,
        LegacyRecallCredentialCleaner.emailKey,
        LegacyRecallCredentialCleaner.passwordKey,
      ]);
    },
  );

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

  test(
    'legacy verification read failure refuses initialization after both deletes',
    () async {
      final credentials = _MemoryLegacyCredentialStore()
        ..failContainsKey = LegacyRecallCredentialCleaner.emailKey;
      final storage = SecureRecallSupabaseLocalStorage(
        secretStore: _MemorySecretStore(),
        legacyCredentialStore: credentials,
        secureKey: 'invented-secure-key',
        legacyPreferencesKey: 'invented-legacy-key',
      );

      await expectLater(storage.initialize(), throwsStateError);

      expect(credentials.deleteCalls, [
        LegacyRecallCredentialCleaner.emailKey,
        LegacyRecallCredentialCleaner.passwordKey,
      ]);
    },
  );
}

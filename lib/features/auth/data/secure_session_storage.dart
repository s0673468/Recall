import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:health_flutter_shared/health_flutter_shared.dart';

abstract class SessionSecretStore implements SecureStringStore {}

class KeychainSessionSecretStore implements SessionSecretStore {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'com.german.recall.auth',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(storageNamespace: 'recall_auth_session'),
  );

  const KeychainSessionSecretStore();

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

abstract class LegacyCredentialStore {
  Future<void> delete(String key);
  Future<bool> containsKey(String key);
}

class KeychainLegacyCredentialStore implements LegacyCredentialStore {
  // Exact options used by the retired password vault. A new Keychain account
  // cannot erase entries belonging to the old/default service.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'recall_auth'),
  );

  const KeychainLegacyCredentialStore();

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class LegacyRecallCredentialCleaner {
  static const emailKey = 'recall.auth.email';
  static const passwordKey = 'recall.auth.password';
  static const _keys = [emailKey, passwordKey];

  final LegacyCredentialStore _store;

  const LegacyRecallCredentialCleaner({
    LegacyCredentialStore store = const KeychainLegacyCredentialStore(),
  }) : _store = store;

  Future<void> clearAndVerify() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final key in _keys) {
      try {
        await _store.delete(key);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    for (final key in _keys) {
      try {
        if (await _store.containsKey(key)) {
          throw StateError(
            'Legacy Recall credential deletion was not verified.',
          );
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}

class RecallSessionKeys {
  final String secureKey;
  final String legacyPreferencesKey;

  const RecallSessionKeys({
    required this.secureKey,
    required this.legacyPreferencesKey,
  });
}

RecallSessionKeys recallSessionKeysForUrl(String url) {
  final host = Uri.tryParse(url)?.host;
  final projectRef = switch (host) {
    final value? when value.isNotEmpty => value.split('.').first,
    _ => url,
  };
  return RecallSessionKeys(
    secureKey: 'recall.secure_auth_token.$projectRef',
    legacyPreferencesKey: 'sb-$projectRef-auth-token',
  );
}

class SecureRecallSupabaseLocalStorage
    extends MigratingSecureSupabaseLocalStorage {
  final LegacyRecallCredentialCleaner _legacyCredentials;
  Future<void>? _initialization;

  SecureRecallSupabaseLocalStorage({
    SessionSecretStore secretStore = const KeychainSessionSecretStore(),
    LegacyCredentialStore legacyCredentialStore =
        const KeychainLegacyCredentialStore(),
    required super.secureKey,
    required super.legacyPreferencesKey,
    super.preferencesLoader,
  }) : _legacyCredentials = LegacyRecallCredentialCleaner(
         store: legacyCredentialStore,
       ),
       super(secretStore: secretStore);

  factory SecureRecallSupabaseLocalStorage.forSupabaseUrl(String url) {
    final keys = recallSessionKeysForUrl(url);
    return SecureRecallSupabaseLocalStorage(
      secureKey: keys.secureKey,
      legacyPreferencesKey: keys.legacyPreferencesKey,
    );
  }

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await super.initialize();
    await _legacyCredentials.clearAndVerify();
  }

  Future<void> persistSessionStrict(String persistSessionString) async {
    await super.persistSession(persistSessionString);
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await persistSessionStrict(persistSessionString);
    } catch (error) {
      // Supabase Flutter invokes LocalStorage callbacks without awaiting them.
      // RecallApi separately awaits the strict method for user-driven auth.
      debugPrint('Recall: background session persistence failed: $error');
    }
  }

  Future<void> removePersistedSessionStrict() async {
    await initialize();
    Object? sessionError;
    StackTrace? sessionStackTrace;
    try {
      await super.removePersistedSession();
    } catch (error, stackTrace) {
      sessionError = error;
      sessionStackTrace = stackTrace;
    }
    await _legacyCredentials.clearAndVerify();
    if (sessionError != null) {
      Error.throwWithStackTrace(
        sessionError,
        sessionStackTrace ?? StackTrace.current,
      );
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await removePersistedSessionStrict();
    } catch (error) {
      // See persistSession: framework callbacks are best-effort, while the
      // explicit RecallApi sign-out path awaits and surfaces strict deletion.
      debugPrint('Recall: background session deletion failed: $error');
    }
  }
}

bool supportsRecallSecureSession({
  required bool isWeb,
  required TargetPlatform targetPlatform,
}) =>
    !isWeb &&
    (targetPlatform == TargetPlatform.iOS ||
        targetPlatform == TargetPlatform.android);

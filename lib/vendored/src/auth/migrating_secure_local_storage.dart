import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Minimal secure-string boundary implemented by each native app's Keychain
/// or encrypted-storage adapter.
abstract class SecureStringStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Moves one legacy SharedPreferences value into secure storage using a
/// copy-readback-delete sequence. The legacy value remains intact if the
/// secure write cannot be verified.
class MigratingSecureStringStore {
  final SecureStringStore _secretStore;
  final String secureKey;
  final String legacyPreferencesKey;
  final Future<SharedPreferences> Function() _preferencesLoader;
  SharedPreferences? _preferences;

  MigratingSecureStringStore({
    required SecureStringStore secretStore,
    required this.secureKey,
    required this.legacyPreferencesKey,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _secretStore = secretStore,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  Future<void> initialize() async {
    _preferences ??= await _preferencesLoader();
  }

  Future<String?> read() async {
    await initialize();
    final secureValue = await _secretStore.read(secureKey);
    if (secureValue != null && secureValue.isNotEmpty) {
      await _removeLegacy();
      return secureValue;
    }
    final legacyValue = _preferences!.getString(legacyPreferencesKey);
    if (legacyValue == null || legacyValue.isEmpty) return null;
    await _writeAndVerify(legacyValue);
    await _removeLegacy();
    return legacyValue;
  }

  Future<void> write(String value) async {
    await initialize();
    await _writeAndVerify(value);
    await _removeLegacy();
  }

  Future<void> delete() async {
    await initialize();
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _secretStore.delete(secureKey);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      if (await _secretStore.read(secureKey) != null) {
        throw StateError('Secure session deletion was not verified.');
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    await _removeLegacy();
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<void> _writeAndVerify(String value) async {
    await _secretStore.write(secureKey, value);
    if (await _secretStore.read(secureKey) != value) {
      throw StateError('Secure storage did not verify the persisted session.');
    }
  }

  Future<void> _removeLegacy() async {
    await _preferences!.remove(legacyPreferencesKey);
    if (_preferences!.containsKey(legacyPreferencesKey)) {
      throw StateError('Legacy session deletion was not verified.');
    }
  }
}

/// Supabase LocalStorage backed by [MigratingSecureStringStore].
class MigratingSecureSupabaseLocalStorage extends LocalStorage {
  final MigratingSecureStringStore storage;

  MigratingSecureSupabaseLocalStorage({
    required SecureStringStore secretStore,
    required String secureKey,
    required String legacyPreferencesKey,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : storage = MigratingSecureStringStore(
         secretStore: secretStore,
         secureKey: secureKey,
         legacyPreferencesKey: legacyPreferencesKey,
         preferencesLoader: preferencesLoader,
       );

  @override
  Future<void> initialize() => storage.initialize();
  @override
  Future<String?> accessToken() async {
    await initialize();
    return storage.read();
  }

  @override
  Future<bool> hasAccessToken() async => (await accessToken()) != null;
  @override
  Future<void> persistSession(String persistSessionString) async {
    await initialize();
    await storage.write(persistSessionString);
  }

  @override
  Future<void> removePersistedSession() async {
    await initialize();
    await storage.delete();
  }
}

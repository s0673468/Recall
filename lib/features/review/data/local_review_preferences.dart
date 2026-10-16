import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'local_review_write_failure_stub.dart'
    if (dart.library.js_interop) 'local_review_write_failure_web.dart'
    as write_failure;

/// The backend positively rejected a write before storing any of its value.
/// This differs from an unknown acknowledgement and admits no pending action.
class LocalPreferenceWriteNotCommitted implements Exception {
  const LocalPreferenceWriteNotCommitted();

  @override
  String toString() => 'Preference write was refused before commit.';
}

/// A native-backed view of legacy preferences, independent of the global cache.
class LocalReviewPreferences {
  LocalReviewPreferences._(this._writer, this._values);

  static const _prefix = 'flutter.';
  final SharedPreferences _writer;
  final Map<String, Object> _values;

  /// Read persisted values without reloading or replacing SharedPreferences.
  static Future<LocalReviewPreferences> readSnapshot(
    SharedPreferences writer,
  ) async {
    final native = await SharedPreferencesStorePlatform.instance.getAll();
    return LocalReviewPreferences._(writer, {
      for (final entry in native.entries)
        if (entry.key.startsWith(_prefix))
          entry.key.substring(_prefix.length): entry.value,
    });
  }

  /// A write-only view for blind writes. It never reads native truth, so a
  /// failed snapshot read cannot block an independent write. Do not use it for
  /// read-modify-write: its reads are empty.
  static LocalReviewPreferences writeOnly(SharedPreferences writer) =>
      LocalReviewPreferences._(writer, {});

  String? getString(String key) => _values[key] as String?;

  bool? getBool(String key) => _values[key] as bool?;

  Set<String> getKeys() => Set<String>.from(_values.keys);

  Future<bool> setString(String key, String value) async {
    final stored = await _write(() => _writer.setString(key, value));
    if (stored) _values[key] = value;
    return stored;
  }

  Future<bool> setBool(String key, bool value) async {
    final stored = await _write(() => _writer.setBool(key, value));
    if (stored) _values[key] = value;
    return stored;
  }

  Future<bool> _write(Future<bool> Function() action) async {
    final backend = SharedPreferencesStorePlatform.instance;
    try {
      return await action();
    } catch (error, stackTrace) {
      final definitelyUncommitted =
          error is LocalPreferenceWriteNotCommitted ||
          write_failure.isDefinitelyUncommittedWrite(error, backend);
      if (definitelyUncommitted) {
        // SharedPreferences updates its in-memory cache before the native
        // call, so a definite refusal leaves the rejected value in the shared
        // cache. A later acknowledgement merge reads that cache and would
        // otherwise persist the rejected review. Resync best-effort; the
        // refusal itself is never masked.
        try {
          await _writer.reload();
        } catch (_) {
          // A failed resync cannot grant retry authority.
        }
        if (error is LocalPreferenceWriteNotCommitted) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        Error.throwWithStackTrace(
          const LocalPreferenceWriteNotCommitted(),
          stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<bool> remove(String key) async {
    final stored = await _writer.remove(key);
    if (stored) _values.remove(key);
    return stored;
  }
}

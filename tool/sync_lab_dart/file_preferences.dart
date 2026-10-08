// Synthetic on-disk platform adapter, not evidence of native/browser plugin
// behavior. Production SharedPreferences + LocalReviewStore run unchanged.
import 'dart:convert';
import 'dart:io';

// Already pinned transitively by shared_preferences; no dependency changes.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class LabFilePreferences extends SharedPreferencesStorePlatform {
  final Directory directory;
  String? deviceId;
  bool failNextWrite = false;
  final List<Map<String, Object?>> trace = [];

  LabFilePreferences(this.directory);

  File get _file {
    final id = deviceId;
    if (id == null || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) {
      throw StateError('Missing or unsafe synthetic device id');
    }
    return File('${directory.path}/$id.preferences.json');
  }

  Map<String, Object> _read() {
    final file = _file;
    if (!file.existsSync()) return {};
    return Map<String, Object>.from(jsonDecode(file.readAsStringSync()) as Map);
  }

  Future<bool> _write(Map<String, Object> values) async {
    if (failNextWrite) {
      failNextWrite = false;
      trace.add({
        'surface': 'preferences.write',
        'deviceId': deviceId,
        'ok': false,
      });
      return false;
    }
    final file = _file;
    final temporary = File('${file.path}.next');
    // Parent creates private 0700 directory and starts process with umask 077.
    await temporary.writeAsString(jsonEncode(values), flush: true);
    await temporary.rename(file.path);
    trace.add({
      'surface': 'preferences.write',
      'deviceId': deviceId,
      'ok': true,
    });
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => _read();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _write(_read()..[key] = value);

  @override
  Future<bool> remove(String key) async => _write(_read()..remove(key));

  @override
  Future<bool> clear() async => _write({});
}

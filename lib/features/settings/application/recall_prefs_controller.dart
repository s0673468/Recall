import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../review/data/recall_api.dart';
import '../domain/recall_prefs.dart';

/// Owns Recall's study preferences ([RecallPrefs]). Loads the local mirror
/// first (so settings apply offline and on a cold open), then refreshes from
/// the cloud `recall_prefs` row; writes go through both local + cloud
/// (last-write-wins is fine for a single user).
///
/// [hasStoredPrefs] distinguishes "a value was actually stored" from the pure
/// defaults, so the review controller only lets prefs override the FSRS
/// retention once the user (or a prior session) has set it.
class RecallPrefsController extends ChangeNotifier {
  static const localKey = 'recall_prefs_v1';

  final RecallApi api;
  final Future<SharedPreferences> Function() _prefsLoader;

  RecallPrefsController({
    required this.api,
    Future<SharedPreferences> Function()? prefsLoader,
  }) : _prefsLoader = prefsLoader ?? SharedPreferences.getInstance;

  RecallPrefs _value = const RecallPrefs();
  bool _hasStored = false;

  RecallPrefs get value => _value;
  bool get hasStoredPrefs => _hasStored;

  /// Hydrate from the local mirror, then the cloud. Never throws.
  Future<void> load() async {
    final prefs = await _prefsLoader();
    final localRaw = prefs.getString(localKey);
    if (localRaw != null) {
      try {
        _value = RecallPrefs.fromJson(jsonDecode(localRaw));
        _hasStored = true;
        notifyListeners();
      } catch (e) {
        debugPrint('Recall: local prefs decode failed (non-fatal): $e');
      }
    }

    try {
      final cloud = await api.fetchRecallPrefs();
      if (cloud != null) {
        _value = RecallPrefs.fromJson(cloud);
        _hasStored = true;
        await _mirror(prefs);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Recall: cloud prefs unavailable (non-fatal): $e');
    }
  }

  /// Apply a new preferences value: update in-memory + local mirror
  /// immediately, then best-effort write-through to the cloud.
  Future<void> update(RecallPrefs next) async {
    if (next == _value && _hasStored) return;
    _value = next;
    _hasStored = true;
    notifyListeners();

    final prefs = await _prefsLoader();
    await _mirror(prefs);
    try {
      await api.saveRecallPrefs(next.toJson());
    } catch (e) {
      debugPrint('Recall: prefs cloud write deferred (offline?): $e');
    }
  }

  Future<void> _mirror(SharedPreferences prefs) =>
      prefs.setString(localKey, jsonEncode(_value.toJson()));
}

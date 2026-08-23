import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../review/data/recall_api.dart';
import '../domain/recall_prefs.dart';

/// Owns Recall's account-scoped study preferences ([RecallPrefs]).
///
/// Local hydration is deliberately separate from [syncOwner]: the signed-in
/// queue can use the owner's last known settings immediately, while replaying a
/// pending write and refreshing from Supabase happen off the startup path.
/// Every offline update keeps one durable latest-value pending record. That
/// record is replayed before any cloud read and remains authoritative until the
/// server accepts it.
class RecallPrefsController extends ChangeNotifier {
  /// Legacy single-account mirror. It has no owner marker, so product startup
  /// discards it instead of ever assigning it to an authenticated account.
  static const localKey = 'recall_prefs_v1';
  static const _ownerLocalPrefix = 'recall_prefs_v2';
  static const _ownerPendingPrefix = 'recall_prefs_pending_v1';
  static const _ownerCorruptPendingPrefix = 'recall_prefs_pending_corrupt_v1';

  final RecallApi api;
  final Future<SharedPreferences> Function() _prefsLoader;

  RecallPrefsController({
    required this.api,
    Future<SharedPreferences> Function()? prefsLoader,
  }) : _prefsLoader = prefsLoader ?? SharedPreferences.getInstance;

  RecallPrefs _value = const RecallPrefs();
  bool _hasStored = false;
  String? _ownerId;
  bool _ownerReady = false;
  int _version = 0;
  Future<void> _localTail = Future<void>.value();
  Future<void> _syncTail = Future<void>.value();

  RecallPrefs get value => _value;
  bool get hasStoredPrefs => _hasStored;
  String? get activeOwnerId => _ownerId;

  static String localKeyForOwner(String ownerId) =>
      '$_ownerLocalPrefix:${_ownerKey(ownerId)}';

  static String pendingKeyForOwner(String ownerId) =>
      '$_ownerPendingPrefix:${_ownerKey(ownerId)}';

  @visibleForTesting
  static String corruptPendingKeyForOwner(String ownerId) =>
      '$_ownerCorruptPendingPrefix:${_ownerKey(ownerId)}';

  static String _ownerKey(String ownerId) =>
      sha256.convert(utf8.encode(ownerId)).toString();

  /// Backwards-compatible full hydration for non-product callers and older
  /// tests. Product startup uses [activateOwner] plus an unawaited [syncOwner]
  /// so cloud latency never gates first paint or the offline queue.
  Future<void> load() async {
    final ownerId = api.currentUser?.id;
    if (ownerId == null) {
      await _loadLegacyCompatibility();
      await _syncLegacyCompatibility();
      return;
    }
    await activateOwner(ownerId);
    await syncOwner();
  }

  /// Selects [ownerId] and hydrates only that owner's on-device state.
  Future<void> activateOwner(String ownerId) {
    if (ownerId.isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'must not be empty');
    }
    return _withLocalLock(() async {
      if (_ownerId == ownerId && _ownerReady) return;

      _ownerId = ownerId;
      _ownerReady = false;
      _version++;
      _resetValue();

      final prefs = await _prefsLoader();
      final ownerKey = localKeyForOwner(ownerId);
      final localRaw = prefs.getString(ownerKey);

      // The old mirror has no owner marker. Even a restored session cannot
      // prove which account wrote it, so discard it and let the owner-scoped
      // mirror or Supabase source of truth restore the current account.
      if (prefs.containsKey(localKey)) {
        await _removeStrict(prefs, localKey);
      }

      final pendingRaw = prefs.getString(pendingKeyForOwner(ownerId));
      final pending = _decode(pendingRaw, pending: true);
      final local = _decode(localRaw);
      final selected = pending ?? local;
      if (selected != null) {
        _value = selected;
        _hasStored = true;
      }
      _ownerReady = true;
      notifyListeners();
    });
  }

  /// Clears account-specific values from memory without deleting that owner's
  /// mirror or pending write. Returning to the account restores both.
  Future<void> releaseOwner() => _withLocalLock(() async {
    _ownerId = null;
    _ownerReady = false;
    _version++;
    _resetValue();
    try {
      final prefs = await _prefsLoader();
      await _removeStrict(prefs, localKey);
    } finally {
      notifyListeners();
    }
  });

  /// Replays the current owner's latest pending value before considering cloud
  /// state. Never throws: this is a reconnect/startup optimization and the
  /// durable local pending record is the recovery contract.
  Future<void> syncOwner() {
    final run = _syncTail.then((_) => _syncOwnerOnce());
    _syncTail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _syncOwnerOnce() async {
    final ownerId = _ownerId;
    if (ownerId == null || !_ownerReady) return;
    if (api.currentUser?.id != ownerId) return;

    try {
      final prefs = await _prefsLoader();
      final pendingKey = pendingKeyForOwner(ownerId);
      final pendingRaw = prefs.getString(pendingKey);
      if (pendingRaw != null) {
        final pending = _decode(pendingRaw, pending: true);
        if (pending == null) {
          // A malformed latest-value record cannot be replayed, but leaving it
          // in the authoritative pending slot would block every later cloud
          // refresh. Preserve the raw recovery evidence under the same hashed
          // owner scope, then clear only the unchanged corrupt value.
          await _withLocalLock(() async {
            if (prefs.getString(pendingKey) != pendingRaw) return;
            await _setStringStrict(
              prefs,
              corruptPendingKeyForOwner(ownerId),
              pendingRaw,
            );
            await _removeStrict(prefs, pendingKey);
          });
        } else {
          if (_ownerId != ownerId || api.currentUser?.id != ownerId) return;
          try {
            await api.saveRecallPrefs(pending.toJson());
          } catch (_) {
            debugPrint('Recall: prefs cloud write deferred (offline?)');
            return;
          }

          // A newer update may have replaced the pending value while this
          // write was in flight. Clear only the exact value the server accepted.
          await _withLocalLock(() async {
            if (prefs.getString(pendingKey) == pendingRaw) {
              await _removeStrict(prefs, pendingKey);
            }
          });
          // The just-replayed local value is authoritative. Do not immediately
          // replace it with a lagging read replica or stale fake/cloud response.
          return;
        }
      }

      final versionAtFetch = _version;
      Map<String, dynamic>? cloud;
      try {
        if (_ownerId != ownerId || api.currentUser?.id != ownerId) return;
        cloud = await api.fetchRecallPrefs();
      } catch (_) {
        debugPrint('Recall: cloud prefs unavailable (non-fatal)');
        return;
      }
      if (cloud == null) return;
      final next = RecallPrefs.fromJson(cloud);
      await _withLocalLock(() async {
        if (_ownerId != ownerId ||
            !_ownerReady ||
            _version != versionAtFetch ||
            prefs.containsKey(pendingKey)) {
          return;
        }
        await _setStringStrict(
          prefs,
          localKeyForOwner(ownerId),
          jsonEncode(next.toJson()),
        );
        _value = next;
        _hasStored = true;
        notifyListeners();
      });
    } catch (_) {
      debugPrint('Recall: local prefs sync unavailable (non-fatal)');
    }
  }

  /// Applies a new value locally, persists the latest-value pending record,
  /// then makes one best-effort cloud replay.
  Future<void> update(RecallPrefs next) async {
    final ownerId = _ownerId;
    if (ownerId == null) {
      await _updateLegacyCompatibility(next);
      return;
    }
    if (next == _value && _hasStored) {
      await syncOwner();
      return;
    }

    _value = next;
    _hasStored = true;
    _version++;
    notifyListeners();

    final encoded = jsonEncode(next.toJson());
    await _withLocalLock(() async {
      final prefs = await _prefsLoader();
      // Pending first: a crash between these writes still restores the user's
      // new value and can never let stale cloud state win.
      await _setStringStrict(prefs, pendingKeyForOwner(ownerId), encoded);
      await _setStringStrict(prefs, localKeyForOwner(ownerId), encoded);
    });
    if (_ownerId == ownerId) await syncOwner();
  }

  RecallPrefs? _decode(String? raw, {bool pending = false}) {
    if (raw == null) return null;
    try {
      return RecallPrefs.fromJson(jsonDecode(raw));
    } catch (_) {
      debugPrint(
        pending
            ? 'Recall: pending prefs decode failed (non-fatal)'
            : 'Recall: local prefs decode failed (non-fatal)',
      );
      return null;
    }
  }

  void _resetValue() {
    _value = const RecallPrefs();
    _hasStored = false;
  }

  Future<void> _withLocalLock(Future<void> Function() action) {
    final run = _localTail.then((_) => action());
    _localTail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _setStringStrict(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    if (!await prefs.setString(key, value)) {
      throw StateError('Recall preferences could not be persisted.');
    }
  }

  Future<void> _removeStrict(SharedPreferences prefs, String key) async {
    if (!await prefs.remove(key)) {
      throw StateError('Recall preferences could not be released.');
    }
  }

  Future<void> _loadLegacyCompatibility() async {
    final prefs = await _prefsLoader();
    final local = _decode(prefs.getString(localKey));
    if (local != null) {
      _value = local;
      _hasStored = true;
      notifyListeners();
    }
  }

  Future<void> _syncLegacyCompatibility() async {
    try {
      final cloud = await api.fetchRecallPrefs();
      if (cloud == null) return;
      _value = RecallPrefs.fromJson(cloud);
      _hasStored = true;
      final prefs = await _prefsLoader();
      await prefs.setString(localKey, jsonEncode(_value.toJson()));
      notifyListeners();
    } catch (_) {
      debugPrint('Recall: cloud prefs unavailable (non-fatal)');
    }
  }

  Future<void> _updateLegacyCompatibility(RecallPrefs next) async {
    if (next == _value && _hasStored) return;
    _value = next;
    _hasStored = true;
    notifyListeners();
    final prefs = await _prefsLoader();
    await prefs.setString(localKey, jsonEncode(next.toJson()));
    try {
      await api.saveRecallPrefs(next.toJson());
    } catch (_) {
      debugPrint('Recall: prefs cloud write deferred (offline?)');
    }
  }
}

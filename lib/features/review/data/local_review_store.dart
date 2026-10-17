import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catch_up_state.dart';
import 'local_review_preferences.dart';
import 'models.dart';

/// On-device persistence so Recall opens instantly and works offline:
///  - a snapshot of the last-loaded decks + study queue, and
///  - an append-only outbox of reviews done while offline (or that failed to
///    sync), flushed to Supabase on the next launch/foreground.
///
/// Supabase remains the source of truth; this cache is disposable.
///
/// Outbox mutations are serialized through [_withOutboxLock]: the flush now
/// runs behind the UI, so an enqueue (new rating) can arrive while a flush is
/// rewriting the list — unserialized, that read-modify-write race can
/// resurrect an already-sent review (double-apply) or drop a fresh one.
///
/// Note flags (bad-card reports) live in their own [_flagOutboxKey] list with
/// the same enqueue/read/remove shape as the review outbox, sharing the one
/// lock so a flag write never races a review write. They flush through a
/// separate loop in the controller so a flag delivery failure (e.g. the
/// note_flags table not existing yet) can never stall the review sync.
class LocalReviewStore {
  static const _snapshotKey = 'recall_snapshot_v1';
  static const _outboxKey = 'recall_outbox_v1';
  static const _flagOutboxKey = 'flag_outbox_v1';
  static const _hiddenCardsKey = 'recall_hidden_cards_v1';
  static const catchUpKey = 'recall_catch_up_v1';
  static const remediationKey = 'recall_remediation_v1';
  static const installIdKey = 'recall_install_id_v1';
  static const _legacyOwnerClaimKey = 'recall_local_state_owner_v1';
  static const _ownerMigrationKey = 'recall_local_state_migrated_v1';
  static const maxDailyRemediations = 3;

  Future<void> _outboxTail = Future.value();
  static Future<void>? _ownerMigrationTail;
  Future<SharedPreferences>? _prefsFuture;
  // A false native result or a proven quota refusal is a definite refusal; a
  // thrown call has unknown commit status. Contract B: a definite refusal is
  // never retained, replayed or sent, so the caller's fresh-ID redo is the
  // only copy that can ever persist. Its id is tombstoned here because its
  // optimistic cache value can survive in the shared cache, and an
  // acknowledgement merge must never persist it from there. A quota refusal's
  // cache value is also resynced in LocalReviewPreferences. Unknown appends
  // stay quarantined only in this Store and under the exact scoped key.
  final Map<String, List<Map<String, dynamic>>> _uncertainAppends = {};
  final Map<String, Set<Object>> _refusedIds = {};
  String? _installId;
  int _eventSequence = 0;
  String? _activeOwnerScope;
  bool _ownerAware = false;

  String? get activeOwnerScope => _activeOwnerScope;
  bool get ownerAware => _ownerAware;

  /// Whether [ownerId] is the account whose local namespace is active.
  ///
  /// The raw account id is never persisted. Callers use this check to bind
  /// asynchronous work to both the authenticated session and its hashed local
  /// namespace, so a delayed owner hand-off cannot send one account's outbox
  /// through another account's API session.
  bool isActiveOwner(String ownerId) =>
      _activeOwnerScope == _scopeForOwner(ownerId);

  /// Read native truth for exactly [keys]. Each operation still makes the
  /// same single native read, so a failed read surfaces exactly as before,
  /// but never ships unrelated values (such as card snapshots) to Dart.
  Future<LocalReviewPreferences> _prefsFor(Iterable<String> keys) async {
    final writer = await (_prefsFuture ??= SharedPreferences.getInstance());
    return LocalReviewPreferences.readSnapshot(writer, keys: keys);
  }

  /// Read every native preference. Only [clear] needs this, to find the
  /// per-deck snapshot keys it removes.
  Future<LocalReviewPreferences> get _allPrefs async {
    final writer = await (_prefsFuture ??= SharedPreferences.getInstance());
    return LocalReviewPreferences.readSnapshot(writer);
  }

  Future<SharedPreferences> get _writerPrefs =>
      _prefsFuture ??= SharedPreferences.getInstance();

  /// Random source for durable ids. `Random.secure()` can be unavailable on
  /// some embedders; uniqueness (not unpredictability) is what matters here,
  /// so a plain PRNG is an acceptable fallback.
  static final Random _random = () {
    try {
      return Random.secure();
    } on UnsupportedError {
      return Random();
    }
  }();

  /// This installation's stable identity, minted once and reused for the life
  /// of the install. It scopes durable event ids to one device so two devices
  /// studying the same collection can never mint the same id.
  ///
  /// Deliberately NOT cleared by [clear]: it identifies the device, not the
  /// user, and keeping it stable across sign-out preserves the uniqueness
  /// guarantee for reviews still queued from a previous session.
  Future<String> installId() {
    final cached = _installId;
    if (cached != null) return Future.value(cached);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([installIdKey]);
      var value = prefs.getString(installIdKey);
      if (value == null || value.isEmpty) {
        value = _token();
        await prefs.setString(installIdKey, value);
      }
      return _installId = value;
    });
  }

  /// A durable, globally unique id for one study action.
  ///
  /// Three parts, each covering a different collision: the install id
  /// separates devices, the counter separates actions within a run, and the
  /// random suffix separates runs. The suffix is what makes the id independent
  /// of the clock — the outbox outlives a restart while the counter resets, so
  /// a device whose clock rolled back would otherwise mint an id it had
  /// already used and the server would discard the review as a replay.
  Future<String> newEventId() async {
    final install = await installId();
    return '$install-${++_eventSequence}-${_token()}';
  }

  /// ~62 bits of entropy over a lowercase-alphanumeric alphabet.
  ///
  /// Deliberately built from small `nextInt` draws rather than shifted 32-bit
  /// integers: Recall also builds to web, where Dart ints are JS doubles and a
  /// `1 << 32` would silently collapse to 1 — every token would be identical
  /// on exactly the platform where this is hardest to notice.
  static String _token([int length = 12]) {
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(_random.nextInt(alphabet.length)),
    ]);
  }

  Future<T> _withOutboxLock<T>(Future<T> Function() action) {
    final run = _outboxTail.then((_) => action());
    // Keep the chain alive past failures so one error can't wedge the lock.
    _outboxTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<T> _withOwnerMigrationLock<T>(Future<T> Function() action) {
    // Create the idle starting point in this caller's Zone. A completed static
    // Future can otherwise retain a drained Zone between Flutter tests.
    final predecessor = _ownerMigrationTail ?? Future<void>.value();
    final run = predecessor.then((_) => action());
    late final Future<void> tail;
    // Settle the caller's Future only after releasing the idle static tail.
    // A queued successor replaces it, so this run cannot clear that successor.
    final completed = run.then<T>(
      (value) {
        if (identical(_ownerMigrationTail, tail)) _ownerMigrationTail = null;
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_ownerMigrationTail, tail)) _ownerMigrationTail = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    // Keep the queue live past failures without retaining its settled Future.
    tail = completed.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _ownerMigrationTail = tail;
    return completed;
  }

  /// Select the account namespace used by every cache and durable outbox.
  ///
  /// The first upgraded account claims the legacy unscoped values. They are
  /// copied once, then left untouched as recovery evidence; later accounts can
  /// never inherit them. The install id deliberately remains device-scoped.
  Future<void> activateOwner(String ownerId) {
    if (ownerId.trim().isEmpty) {
      return Future.error(ArgumentError.value(ownerId, 'ownerId'));
    }
    final scope = _scopeForOwner(ownerId);
    final migrationKey = '$_ownerMigrationKey:$scope';
    const migratedBases = [
      _snapshotKey,
      _outboxKey,
      _flagOutboxKey,
      catchUpKey,
      remediationKey,
    ];
    return _withOutboxLock(
      () => _withOwnerMigrationLock(() async {
        final prefs = await _prefsFor([
          _legacyOwnerClaimKey,
          migrationKey,
          for (final base in migratedBases) ...[base, _scopedKey(base, scope)],
        ]);
        // The isolated view reads persisted values without reloading the
        // shared settings cache. It includes only acknowledged writes here.
        final claimed = prefs.getString(_legacyOwnerClaimKey);
        if (claimed == null) {
          if (!await prefs.setString(_legacyOwnerClaimKey, scope)) {
            throw LocalOutboxWriteException(_legacyOwnerClaimKey);
          }
        }
        final ownerClaim = claimed ?? scope;
        if (ownerClaim == scope && prefs.getBool(migrationKey) != true) {
          for (final base in migratedBases) {
            final legacy = prefs.getString(base);
            final scoped = _scopedKey(base, scope);
            if (legacy != null && prefs.getString(scoped) == null) {
              if (!await prefs.setString(scoped, legacy)) {
                throw LocalOutboxWriteException(scoped);
              }
            }
          }
          if (!await prefs.setBool(migrationKey, true)) {
            throw LocalOutboxWriteException(migrationKey);
          }
        }
        _ownerAware = true;
        _activeOwnerScope = scope;
      }),
    );
  }

  Future<void> releaseOwner() => _withOutboxLock(() async {
    _ownerAware = true;
    _activeOwnerScope = null;
  });

  String _storageKey(String base, {String? ownerScope}) {
    final scope = ownerScope ?? _activeOwnerScope;
    if (scope != null) return _scopedKey(base, scope);
    if (_ownerAware) {
      throw StateError('Recall local state has no active owner.');
    }
    return base;
  }

  static String _scopedKey(String base, String scope) => '$base:owner:$scope';

  static String _scopeForOwner(String ownerId) =>
      sha256.convert(utf8.encode(ownerId)).toString().substring(0, 24);

  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
    int? deckId,
    int? globalDueCount,
    DateTime? globalDueUpdatedAt,
    bool Function()? canWrite,
  }) async {
    final snapshotKey = _snapshotStorageKey(deckId);
    await _withOutboxLock(() async {
      // Nothing is read back, but the native read still gates the write as
      // before; an empty allowList keeps the old snapshot off the channel.
      final prefs = await _prefsFor(const []);
      if (canWrite != null && !canWrite()) return;
      await prefs.setString(
        snapshotKey,
        jsonEncode({
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'globalDueCount': globalDueCount,
          'globalDueUpdatedAt': globalDueUpdatedAt?.toUtc().toIso8601String(),
          'decks': [for (final d in decks) d.toJson()],
          'queue': [for (final c in queue) c.toJson()],
        }),
      );
    });
  }

  Future<
    ({
      List<DeckRow> decks,
      List<ReviewCard> queue,
      int? globalDueCount,
      DateTime? globalDueUpdatedAt,
    })?
  >
  loadSnapshot({int? deckId}) async {
    final snapshotKey = _snapshotStorageKey(deckId);
    final prefs = await _prefsFor([snapshotKey]);
    final raw = prefs.getString(snapshotKey);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        decks: [
          for (final d in (m['decks'] as List))
            DeckRow.fromJson(Map<String, dynamic>.from(d as Map)),
        ],
        queue: [
          for (final c in (m['queue'] as List))
            ReviewCard.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        globalDueCount: (m['globalDueCount'] as num?)?.toInt(),
        globalDueUpdatedAt: m['globalDueUpdatedAt'] == null
            ? null
            : DateTime.tryParse(m['globalDueUpdatedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  String _snapshotStorageKey(int? deckId, {String? ownerScope}) {
    final base = _storageKey(_snapshotKey, ownerScope: ownerScope);
    return deckId == null ? base : '$base:deck:$deckId';
  }

  /// Append one review; returns the new pending count so the caller can
  /// update its badge without re-reading + re-decoding the whole outbox.
  Future<int> enqueueReview(
    Map<String, dynamic> entry, {
    String? ownerScope,
    bool Function()? canWrite,
  }) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final list = _readOutbox(prefs, key);
      // A producer may lose its session while waiting for another local write.
      // Cancel only before append; an already durable event is never removed.
      if (canWrite != null && !canWrite()) return list.length;
      return _appendProducer(prefs, key, list, {
        ...entry,
        'delivery_attempted': entry['delivery_attempted'] ?? false,
      });
    });
  }

  /// Read the queued reviews. Serialized through the outbox lock so a flush
  /// starting right after an undo's [removeEntry] can never read the stale
  /// pre-removal list and deliver a review the user just took back.
  Future<List<Map<String, dynamic>>> outbox({String? ownerScope}) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      return _readOutbox(prefs, key);
    });
  }

  /// Durably close the local Undo window before sending, including attempts
  /// whose response may be lost. Serialized with removal so only one wins.
  Future<bool> markReviewAttempted(Object clientId, {String? ownerScope}) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final list = _readOutbox(prefs, key);
      final index = list.indexWhere((e) => e['client_id'] == clientId);
      if (index < 0) return false;
      list[index]['delivery_attempted'] = true;
      await _writeList(prefs, key, list);
      _dropPendingId(key, clientId);
      return true;
    });
  }

  /// Drain only captured reviews whose server acknowledgement returned.
  /// Fresh native state may already have lost these ids in another tab; its
  /// next queued action must never be removed in their place. Unidentified or
  /// conflicting records remain queued rather than guessing by count.
  Future<int> removeAcknowledgedReviews(
    Iterable<Map<String, dynamic>> acknowledged, {
    String? ownerScope,
  }) => _removeAcknowledged(
    _storageKey(_outboxKey, ownerScope: ownerScope),
    acknowledged,
    legacyReviews: true,
  );

  /// Flag delivery uses the same identity guard in its separate owner outbox.
  Future<int> removeAcknowledgedFlags(
    Iterable<Map<String, dynamic>> acknowledged, {
    String? ownerScope,
  }) => _removeAcknowledged(
    _storageKey(_flagOutboxKey, ownerScope: ownerScope),
    acknowledged,
  );

  Future<int> _removeAcknowledged(
    String key,
    Iterable<Map<String, dynamic>> acknowledged, {
    bool legacyReviews = false,
  }) {
    final captured = [
      for (final entry in acknowledged) Map<String, dynamic>.from(entry),
    ];
    final uniqueAcknowledgedIds = uniqueDeliveryIds(
      captured,
      legacyReviews: legacyReviews,
    );
    final byId = {
      for (final entry in captured)
        if (uniqueAcknowledgedIds.contains(_deliveryId(entry, legacyReviews)))
          _deliveryId(entry, legacyReviews) as Object: entry,
    };
    return _withOutboxLock(() async {
      final writer = await _writerPrefs;
      // Read persisted truth independently, then capture the current same-key
      // cache. Never reload another producer's unacknowledged edits away.
      final nativeView = await LocalReviewPreferences.readSnapshot(
        writer,
        keys: [key],
      );
      final native = _decodeList(nativeView.getString(key), key);
      final cached = _decodeList(writer.getString(key), key);
      // A conflicting payload in either view removes deletion authority for
      // that identity. Identical copies still denote one idempotent event.
      final uniqueIds = uniqueDeliveryIds([
        ...native,
        ...cached,
      ], legacyReviews: legacyReviews);
      List<Map<String, dynamic>> retained(List<Map<String, dynamic>> rows) => [
        for (final entry in rows)
          if (!uniqueIds.contains(_deliveryId(entry, legacyReviews)) ||
              byId[_deliveryId(entry, legacyReviews)] == null ||
              !_sameAcknowledgedPayload(
                entry,
                byId[_deliveryId(entry, legacyReviews)]!,
              ))
            entry,
      ];
      final nativeRemaining = retained(native);
      final cachedAcknowledged = retained(cached);
      final cachedRemaining = [
        for (final entry in cachedAcknowledged)
          // A definite refusal never committed: even a stale shared-cache copy
          // must not be merged into native truth, or a fresh-ID retry would
          // later submit both ratings for the same card.
          if (_refusedIds[key]?.contains(
                _deliveryId(entry, legacyReviews),
              ) !=
              true)
            entry,
      ];
      final remaining = _mergeUnacknowledged(
        nativeRemaining,
        cachedRemaining,
        legacyReviews: legacyReviews,
      );
      // Even an already-empty native view needs an acknowledged cache write
      // when its exact server-accepted action survived a refused eager setter.
      // No matching positive server ACK grants no new write authority, and a
      // refusal tombstone alone never writes.
      if (nativeRemaining.length != native.length ||
          cachedAcknowledged.length != cached.length) {
        await _writeList(nativeView, key, remaining);
      }
      // The server accepted these exact actions, so no uncertain copy of them
      // may remain pending. A failed write above keeps them.
      _settleAcknowledgedPending(key, byId, legacyReviews);
      return remaining.length;
    });
  }

  void _settleAcknowledgedPending(
    String key,
    Map<Object, Map<String, dynamic>> acknowledged,
    bool legacyReviews,
  ) {
    final entries = _uncertainAppends[key];
    entries?.removeWhere((e) {
      final id = _deliveryId(e, legacyReviews);
      final ack = id == null ? null : acknowledged[id];
      return ack != null && _sameAcknowledgedPayload(e, ack);
    });
    if (entries?.isEmpty ?? false) _uncertainAppends.remove(key);
  }

  static List<Map<String, dynamic>> _mergeUnacknowledged(
    List<Map<String, dynamic>> native,
    List<Map<String, dynamic>> cached, {
    required bool legacyReviews,
  }) {
    final merged = [...native];
    final available = <Object?, List<int>>{};
    for (var index = 0; index < native.length; index++) {
      available
          .putIfAbsent(_deliveryId(native[index], legacyReviews), () => [])
          .add(index);
    }
    final matched = <int>{};
    for (final entry in cached) {
      final candidates = available[_deliveryId(entry, legacyReviews)] ?? [];
      int? match;
      for (final index in candidates) {
        if (!matched.contains(index) &&
            _sameAcknowledgedPayload(merged[index], entry)) {
          match = index;
          break;
        }
      }
      if (match == null) {
        merged.add(entry); // Cache-only refusals and all conflicts survive.
        continue;
      }
      matched.add(match);
      // Match copies one-for-one so excess duplicates from either view survive.
      // A durable attempt or unknown old marker must never turn into fresh Undo.
      final current = merged[match];
      if (current['delivery_attempted'] == true ||
          entry['delivery_attempted'] == true) {
        merged[match] = {...current, 'delivery_attempted': true};
      } else if (current['delivery_attempted'] == false &&
          entry['delivery_attempted'] != false) {
        merged[match] = {...current}..remove('delivery_attempted');
        if (entry.containsKey('delivery_attempted')) {
          merged[match]['delivery_attempted'] = entry['delivery_attempted'];
        }
      }
    }
    return merged;
  }

  /// A local-only identity for the exact legacy backend deduplication tuple.
  /// Never persist it or add a client id: the API must keep its original legacy
  /// lookup instead of sending an old rating as a fresh RPC event.
  static Object? reviewDeliveryId(Map<String, dynamic> entry) {
    final clientId = entry['client_id'];
    if (clientId != null) {
      return _hasStableDeliveryId(clientId) ? clientId : null;
    }
    final cardId = entry['card_id'];
    final device = entry['device'];
    final raw = entry['last_review'];
    if (cardId is! int ||
        cardId <= 0 ||
        device is! String ||
        device.trim().isEmpty ||
        raw is! String) {
      return null;
    }
    // Original pre-client-id producers serialized a UTC ISO rating instant.
    // Reject date-only values and calendar overflow accepted by DateTime.parse.
    final match = _legacyRatingAt.firstMatch(raw);
    final timestamp = DateTime.tryParse(raw);
    if (match == null ||
        timestamp == null ||
        !timestamp.isUtc ||
        timestamp.year != int.parse(match[1]!) ||
        timestamp.month != int.parse(match[2]!) ||
        timestamp.day != int.parse(match[3]!) ||
        timestamp.hour != int.parse(match[4]!) ||
        timestamp.minute != int.parse(match[5]!) ||
        timestamp.second != int.parse(match[6]!)) {
      return null;
    }
    return (legacyReviewCardId: cardId, ratingAt: timestamp, device: device);
  }

  static final _legacyRatingAt = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$',
  );

  static Object? _deliveryId(Map<String, dynamic> entry, bool legacyReviews) {
    if (legacyReviews) return reviewDeliveryId(entry);
    final id = entry['client_id'];
    return _hasStableDeliveryId(id) ? id : null;
  }

  /// Identities with one immutable payload in this captured batch. Identical
  /// copies represent the same idempotent server event; conflicting copies and
  /// integer/string wire-id collisions remain ambiguous and cannot be sent.
  static Set<Object> uniqueDeliveryIds(
    Iterable<Map<String, dynamic>> entries, {
    bool legacyReviews = false,
  }) {
    final byKey = <Object, Map<String, dynamic>>{};
    final ids = <Object, Object>{};
    final ambiguous = <Object>{};
    Object key(Object id) => id is int ? id.toString() : id;
    for (final entry in entries) {
      final id = _deliveryId(entry, legacyReviews);
      if (id == null) continue;
      final wireKey = key(id);
      final previous = byKey[wireKey];
      if (previous == null) {
        byKey[wireKey] = entry;
        ids[wireKey] = id;
      } else if (ids[wireKey] != id ||
          !_sameAcknowledgedPayload(previous, entry)) {
        ambiguous.add(wireKey);
      }
    }
    return {
      for (final entry in ids.entries)
        if (!ambiguous.contains(entry.key)) entry.value,
    };
  }

  static bool _hasStableDeliveryId(Object? id) =>
      id is int || (id is String && id.isNotEmpty);

  static bool _sameAcknowledgedPayload(
    Map<String, dynamic> current,
    Map<String, dynamic> acknowledged,
  ) {
    final immutableCurrent = {...current}..remove('delivery_attempted');
    final immutableAcknowledged = {...acknowledged}
      ..remove('delivery_attempted');
    return _sameJsonValue(immutableCurrent, immutableAcknowledged);
  }

  static bool _sameJsonValue(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) =>
                right.containsKey(key) && _sameJsonValue(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_sameJsonValue(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }

  /// Drop the first [count] entries — the prefix a flush just delivered —
  /// and return how many remain. Entries enqueued while the flush ran are
  /// appended after that prefix, so they survive untouched.
  Future<int> removeFirst(int count, {String? ownerScope}) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    if (count <= 0) {
      return _withOutboxLock(() async {
        final prefs = await _prefsFor([key]);
        return _readOutbox(prefs, key).length;
      });
    }
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final list = _readOutbox(prefs, key);
      final remaining = list.length <= count
          ? <Map<String, dynamic>>[]
          : list.sublist(count);
      await _writeList(prefs, key, remaining);
      _dropDrainedIds(key, list.take(count));
      return remaining.length;
    });
  }

  /// Remove only a positively never-attempted queued review. Legacy entries
  /// without this marker are uncertain and remain deliverable. Returns the
  /// removal result and pending count; never drops an ambiguous server commit.
  Future<({bool removed, int remaining})> removeEntry(
    Object clientId, {
    String? ownerScope,
  }) {
    final key = _storageKey(_outboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final list = _readOutbox(prefs, key);
      final before = list.length;
      list.removeWhere(
        (e) => e['client_id'] == clientId && e['delivery_attempted'] == false,
      );
      if (list.length != before) {
        await _writeList(prefs, key, list);
        _dropPendingId(key, clientId);
      }
      return (removed: list.length != before, remaining: list.length);
    });
  }

  /// Settle a review append that threw with unknown commit status against
  /// native truth, read in the outbox lock. Returns the pending count when
  /// native storage holds the review, which also lifts its quarantine; null
  /// when it is absent. Absent is not saved (contract B): its quarantined copy
  /// is dropped and tombstoned like a refusal, so the redo can be saved. A
  /// failed read throws and proves nothing.
  Future<int?> settleUnknownReview(Object clientId, {String? ownerScope}) =>
      _settleUnknown(_storageKey(_outboxKey, ownerScope: ownerScope), clientId);

  /// The flag counterpart of [settleUnknownReview].
  Future<int?> settleUnknownFlag(Object clientId) =>
      _settleUnknown(_storageKey(_flagOutboxKey), clientId);

  Future<int?> _settleUnknown(String key, Object clientId) {
    return _withOutboxLock(() async {
      final durable = _readList(await _prefsFor([key]), key);
      _settleVisiblePending(key, durable);
      if (durable.any((e) => e['client_id'] == clientId)) {
        return _pendingCount(key, durable);
      }
      // The caller reports this action as not saved. Its copy must neither
      // block the redo nor ever persist or sync beside it.
      _dropPendingId(key, clientId);
      _tombstoneRefused(key, clientId);
      return null;
    });
  }

  /// Read the local-only catch-up choice and today's progress. Corrupt or old
  /// presentation state is disposable, so it falls back to opt-out rather
  /// than affecting the review outbox or queue load.
  Future<CatchUpLocalState> loadCatchUpState() {
    final key = _storageKey(catchUpKey);
    return _readCatchUpState(key);
  }

  /// Read the account captured by a delayed Undo, even after an owner change.
  Future<CatchUpLocalState> loadCatchUpStateForOwner(String? ownerScope) {
    final key = _storageKey(catchUpKey, ownerScope: ownerScope);
    return _readCatchUpState(key);
  }

  Future<CatchUpLocalState> _readCatchUpState(String key) {
    return _withOutboxLock(() async {
      // A settled writer may have refused its eager cache update. Read native
      // progress without replacing unrelated pending producer values in cache.
      final prefs = await _prefsFor([key]);
      final raw = prefs.getString(key);
      if (raw == null) return CatchUpLocalState.none;
      try {
        return CatchUpLocalState.fromJson(jsonDecode(raw));
      } catch (_) {
        return CatchUpLocalState.none;
      }
    });
  }

  Future<void> saveCatchUpState(
    CatchUpLocalState state, {
    String? ownerScope,
    bool Function()? canWrite,
  }) {
    final key = _storageKey(catchUpKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      // A blind progress write needs no native snapshot. Reading one first let
      // a failed optional read drop progress for a rating that already committed.
      final prefs = LocalReviewPreferences.writeOnly(await _writerPrefs);
      if (canWrite != null && !canWrite()) return;
      final written = await prefs.setString(key, jsonEncode(state.toJson()));
      if (!written) throw LocalOutboxWriteException(key);
    });
  }

  // --- Flag outbox ---
  //
  // A bad-card report queued mid-review. Mirrors the review outbox exactly
  // (append-only, oldest-first drain, shared lock) but is a wholly separate
  // list so its flush is isolated from the review flush.

  /// Append one flag; returns the new pending flag count.
  Future<int> enqueueFlag(Map<String, dynamic> entry) {
    final key = _storageKey(_flagOutboxKey);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      return _appendProducer(prefs, key, _readList(prefs, key), entry);
    });
  }

  /// Read the queued flags (serialized through the shared outbox lock).
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) {
    final key = _storageKey(_flagOutboxKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      return _readList(prefs, key);
    });
  }

  /// Drop the queued flag whose `client_id` matches — an undone one-tap flag
  /// that has not synced yet. Returns false when a flush already delivered it.
  Future<bool> removeFlagEntry(Object clientId) {
    final key = _storageKey(_flagOutboxKey);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final list = _readList(prefs, key);
      final before = list.length;
      list.removeWhere((e) => e['client_id'] == clientId);
      if (list.length != before) {
        await _writeList(prefs, key, list);
        _dropPendingId(key, clientId);
        return true;
      }
      return false;
    });
  }

  /// Drop the first [count] flags — the prefix a flag flush just delivered —
  /// and return how many remain. Flags enqueued while the flush ran are
  /// appended after that prefix, so they survive untouched.
  Future<int> removeFirstFlag(int count, {String? ownerScope}) {
    final key = _storageKey(_flagOutboxKey, ownerScope: ownerScope);
    if (count <= 0) {
      return _withOutboxLock(() async {
        final prefs = await _prefsFor([key]);
        return _readList(prefs, key).length;
      });
    }
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final list = _readList(prefs, key);
      final remaining = list.length <= count
          ? <Map<String, dynamic>>[]
          : list.sublist(count);
      await _writeList(prefs, key, remaining);
      _dropDrainedIds(key, list.take(count));
      return remaining.length;
    });
  }

  // --- Hidden cards ---
  //
  // Cards German flagged as "don't like" or "delete" stay out of the queue
  // until the weekly review resolves the flag. The server's open flags are the
  // truth; this local set only covers the gap before a flag syncs and offline
  // cold starts, and is replaced wholesale whenever the server set is known.

  Future<Set<int>> hiddenCardIds() {
    final key = _storageKey(_hiddenCardsKey);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      return _readHidden(prefs, key);
    });
  }

  Future<void> addHiddenCard(int cardId) =>
      _updateHidden((ids) => ids..add(cardId));

  Future<void> removeHiddenCard(int cardId) =>
      _updateHidden((ids) => ids..remove(cardId));

  /// Bind a delayed refresh to its namespace and recheck cancellation in-lock.
  Future<void> replaceHiddenCards(
    Set<int> cardIds, {
    String? ownerScope,
    bool Function()? canWrite,
  }) => _updateHidden(
    (_) => {...cardIds},
    ownerScope: ownerScope,
    canWrite: canWrite,
  );

  Future<void> _updateHidden(
    Set<int> Function(Set<int>) change, {
    String? ownerScope,
    bool Function()? canWrite,
  }) {
    final key = _storageKey(_hiddenCardsKey, ownerScope: ownerScope);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      if (canWrite != null && !canWrite()) return;
      final next = change(_readHidden(prefs, key));
      final ids = next.toList()..sort();
      final written = await prefs.setString(key, jsonEncode(ids));
      if (!written) throw LocalOutboxWriteException(key);
    });
  }

  Set<int> _readHidden(LocalReviewPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return <int>{};
    try {
      return {
        for (final id in jsonDecode(raw) as List)
          if (id is num) id.toInt(),
      };
    } catch (_) {
      return <int>{};
    }
  }

  /// Read the local, disposable primer-remediation queue for [now]'s local
  /// calendar day. Entries from an earlier day expire when the app next opens;
  /// the queue is a same-day nudge, not durable user history.
  Future<List<LocalRemediationItem>> remediationQueue({DateTime? now}) {
    final key = _storageKey(remediationKey);
    final today = _dayKey(now ?? DateTime.now());
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final current = _readRemediations(prefs, key)
          .where((item) => item.dayKey == today)
          .take(maxDailyRemediations)
          .toList();
      final all = _readRemediations(prefs, key);
      if (current.length != all.length) {
        await _writeList(prefs, key, [
          for (final item in current) item.toJson(),
        ]);
      }
      return current;
    });
  }

  /// Add unique same-day concept ids, keeping the oldest three. This is a
  /// local cache only: nothing here is sent to Supabase or the review outbox.
  Future<List<LocalRemediationItem>> enqueueRemediation(
    Iterable<String> nodeIds, {
    DateTime? now,
    String? ownerScope,
    bool Function()? canWrite,
  }) {
    final key = _storageKey(remediationKey, ownerScope: ownerScope);
    final queuedAt = now ?? DateTime.now();
    final today = _dayKey(queuedAt);
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final current = _readRemediations(prefs, key)
          .where((item) => item.dayKey == today)
          .take(maxDailyRemediations)
          .toList();
      if (canWrite != null && !canWrite()) return current;
      final seen = {for (final item in current) item.nodeId};
      for (final nodeId in nodeIds) {
        final normalized = nodeId.trim();
        if (normalized.isEmpty || normalized == 'none') continue;
        if (current.length >= maxDailyRemediations) break;
        if (seen.add(normalized)) {
          current.add(
            LocalRemediationItem(nodeId: normalized, queuedAt: queuedAt),
          );
        }
      }
      await _writeList(prefs, key, [for (final item in current) item.toJson()]);
      return current;
    });
  }

  /// Mark one primer remediation as read. Returns false when it was already
  /// gone, which makes repeated route completions harmless.
  Future<bool> completeRemediation(String nodeId, {DateTime? now}) {
    final key = _storageKey(remediationKey);
    final today = _dayKey(now ?? DateTime.now());
    return _withOutboxLock(() async {
      final prefs = await _prefsFor([key]);
      final current = _readRemediations(prefs, key)
          .where((item) => item.dayKey == today)
          .take(maxDailyRemediations)
          .toList();
      final before = current.length;
      current.removeWhere((item) => item.nodeId == nodeId);
      await _writeList(prefs, key, [for (final item in current) item.toJson()]);
      return current.length != before;
    });
  }

  /// Drop the cached snapshot + outboxes (called on sign-out so the next user
  /// on a shared browser can't see the previous user's cards/reviews/flags).
  /// Sign-out opts into [requireEmptyOutboxes]: inspect both outboxes and clear
  /// in one lock acquisition, never using an earlier, possibly stale count.
  /// [ownerScope] pins all removals to the account that began the operation.
  Future<void> clear({
    String? ownerScope,
    bool requireEmptyOutboxes = false,
    bool Function()? canClear,
  }) {
    final snapshotKey = _snapshotStorageKey(null, ownerScope: ownerScope);
    final outboxKey = _storageKey(_outboxKey, ownerScope: ownerScope);
    final flagOutboxKey = _storageKey(_flagOutboxKey, ownerScope: ownerScope);
    final catchUpStorageKey = _storageKey(catchUpKey, ownerScope: ownerScope);
    final remediationStorageKey = _storageKey(
      remediationKey,
      ownerScope: ownerScope,
    );
    final hiddenStorageKey = _storageKey(
      _hiddenCardsKey,
      ownerScope: ownerScope,
    );
    return _withOutboxLock(() async {
      final prefs = await _allPrefs;
      if (requireEmptyOutboxes) {
        final pendingReviews = _pendingCount(
          outboxKey,
          _readOutbox(prefs, outboxKey),
        );
        final pendingFlags = _pendingCount(
          flagOutboxKey,
          _readList(prefs, flagOutboxKey),
        );
        if (pendingReviews + pendingFlags > 0) {
          throw LocalOutboxNotEmptyException(
            pendingReviews: pendingReviews,
            pendingFlags: pendingFlags,
          );
        }
      }
      if (canClear != null && !canClear()) {
        throw StateError('Recall account changed while signing out.');
      }
      for (final key in prefs.getKeys()) {
        if (key == snapshotKey || key.startsWith('$snapshotKey:deck:')) {
          await prefs.remove(key);
        }
      }
      await _removeOutboxForClear(prefs, outboxKey);
      await _removeOutboxForClear(prefs, flagOutboxKey);
      await prefs.remove(catchUpStorageKey);
      await prefs.remove(remediationStorageKey);
      await prefs.remove(hiddenStorageKey);
    });
  }

  Future<void> _removeOutboxForClear(
    LocalReviewPreferences prefs,
    String key,
  ) async {
    // An unacknowledged clear keeps every unknown append quarantined.
    if (!await prefs.remove(key)) throw LocalOutboxWriteException(key);
    _uncertainAppends.remove(key);
    _refusedIds.remove(key);
  }

  Future<int> _appendProducer(
    LocalReviewPreferences prefs,
    String key,
    List<Map<String, dynamic>> durable,
    Map<String, dynamic> entry,
  ) async {
    _settleVisiblePending(key, durable);
    final incomingId = entry['client_id'];
    // A retry under a still-unknown action's own id replaces its quarantined
    // copy: one delivery identity can never apply twice. Durable copies are
    // returned unchanged below.
    if (incomingId != null) _dropPendingId(key, incomingId);
    if (_uncertainAppends[key]?.isNotEmpty ?? false) {
      // An absent action from a thrown native call might already have been
      // delivered and drained elsewhere. Retrying it would double-apply it.
      throw LocalOutboxWriteException(key);
    }

    if (incomingId != null &&
        durable.any((item) => item['client_id'] == incomingId)) {
      // A caller retrying a previously committed action must not duplicate it
      // or replace a durable delivery_attempted marker.
      return durable.length;
    }
    final appended = Map<String, dynamic>.from(entry);
    durable.add(appended);
    final encoded = jsonEncode(durable);
    bool written;
    try {
      written = await prefs.setString(key, encoded);
    } catch (error, stackTrace) {
      if (error is LocalPreferenceWriteNotCommitted) {
        // The incoming action was rejected, so the controller stays on this
        // card. Retaining it would replay it alongside a fresh-ID retry click.
        // Earlier unknown actions keep their original status.
        _tombstoneRefused(key, incomingId);
        rethrow;
      }
      _uncertainAppends.putIfAbsent(key, () => []).add(appended);
      try {
        _settleVisiblePending(key, _readList(await _prefsFor([key]), key));
      } catch (_) {
        // A failed reconciliation read cannot grant retry authority.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (!written) {
      // A definite refusal is dropped like a quota refusal: the next write
      // never persists it beside the caller's fresh-ID redo.
      _tombstoneRefused(key, incomingId);
      throw LocalOutboxWriteException(key);
    }
    _settleVisiblePending(key, durable);
    return durable.length;
  }

  void _settleVisiblePending(String key, List<Map<String, dynamic>> durable) {
    final ids = {
      for (final item in durable)
        if (item['client_id'] != null) item['client_id'],
    };
    final entries = _uncertainAppends[key];
    entries?.removeWhere(
      (e) => e['client_id'] != null && ids.contains(e['client_id']),
    );
    if (entries?.isEmpty ?? false) _uncertainAppends.remove(key);
    // A refused id that later appears durable actually committed (or was
    // re-minted and accepted): it must rejoin acknowledgement merges.
    final refused = _refusedIds[key];
    refused?.removeWhere(ids.contains);
    if (refused?.isEmpty ?? false) _refusedIds.remove(key);
  }

  void _tombstoneRefused(String key, Object? id) {
    if (id != null) _refusedIds.putIfAbsent(key, () => {}).add(id);
  }

  int _pendingCount(String key, List<Map<String, dynamic>> durable) {
    final ids = <Object?>{
      for (final item in durable)
        if (item['client_id'] != null) item['client_id'],
    };
    var count = durable.length;
    for (final item in _uncertainAppends[key] ?? const []) {
      final id = item['client_id'];
      if (id == null || ids.add(id)) count++;
    }
    return count;
  }

  void _dropPendingId(String key, Object id) {
    final entries = _uncertainAppends[key];
    entries?.removeWhere((e) => e['client_id'] == id);
    if (entries?.isEmpty ?? false) _uncertainAppends.remove(key);
  }

  void _dropDrainedIds(String key, Iterable<Map<String, dynamic>> drained) {
    for (final item in drained) {
      final id = item['client_id'];
      if (id != null) _dropPendingId(key, id);
    }
  }

  List<Map<String, dynamic>> _readOutbox(
    LocalReviewPreferences prefs,
    String key,
  ) => _readList(prefs, key);

  List<Map<String, dynamic>> _readList(
    LocalReviewPreferences prefs,
    String key,
  ) => _decodeList(prefs.getString(key), key);

  List<Map<String, dynamic>> _decodeList(String? raw, String key) {
    if (raw == null) return [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List))
          Map<String, dynamic>.from(e as Map),
      ];
    } catch (error) {
      // A malformed durable outbox is not the same as an empty one. Failing
      // closed keeps sign-out and sync from silently deleting study actions
      // that need recovery.
      throw LocalOutboxCorruptException(key, error);
    }
  }

  List<LocalRemediationItem> _readRemediations(
    LocalReviewPreferences prefs,
    String key,
  ) => [
    for (final entry in _readList(prefs, key))
      if (entry['node_id'] is String && entry['queued_at'] is String)
        LocalRemediationItem.fromJson(entry),
  ];

  Future<void> _writeList(
    LocalReviewPreferences prefs,
    String key,
    List<Map<String, dynamic>> list,
  ) async {
    final written = await prefs.setString(key, jsonEncode(list));
    if (!written) {
      throw LocalOutboxWriteException(key);
    }
  }
}

/// One same-day local primer-remediation item. It has no server identity and
/// is intentionally disposable; removing it is the completion state.
class LocalRemediationItem {
  final String nodeId;
  final DateTime queuedAt;

  const LocalRemediationItem({required this.nodeId, required this.queuedAt});

  String get dayKey => _dayKey(queuedAt);

  factory LocalRemediationItem.fromJson(Map<String, dynamic> json) =>
      LocalRemediationItem(
        nodeId: json['node_id'] as String,
        queuedAt: DateTime.parse(json['queued_at'] as String),
      );

  Map<String, dynamic> toJson() => {
    'node_id': nodeId,
    'queued_at': queuedAt.toUtc().toIso8601String(),
  };
}

String _dayKey(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

class LocalOutboxCorruptException implements Exception {
  final String key;
  final Object cause;
  const LocalOutboxCorruptException(this.key, this.cause);

  @override
  String toString() =>
      'Recall could not read the pending study actions ($key).';
}

class LocalOutboxWriteException implements Exception {
  final String key;
  const LocalOutboxWriteException(this.key);

  @override
  String toString() => 'Recall could not save the pending study action ($key).';
}

class LocalOutboxNotEmptyException implements Exception {
  final int pendingReviews;
  final int pendingFlags;

  const LocalOutboxNotEmptyException({
    required this.pendingReviews,
    required this.pendingFlags,
  });
}

import 'dart:math' as math;

/// Ordering applied to the fetched page of new (state 0) cards.
enum NewOrder {
  oldestFirst,
  newestFirst,
  random;

  /// The `new_order` JSON token.
  String get key => switch (this) {
    NewOrder.oldestFirst => 'oldest_first',
    NewOrder.newestFirst => 'newest_first',
    NewOrder.random => 'random',
  };

  String get label => switch (this) {
    NewOrder.oldestFirst => 'Oldest',
    NewOrder.newestFirst => 'Newest',
    NewOrder.random => 'Random',
  };

  static NewOrder fromKey(Object? key) => switch (key) {
    'newest_first' => NewOrder.newestFirst,
    'random' => NewOrder.random,
    _ => NewOrder.oldestFirst,
  };
}

/// Recall's per-user study preferences, persisted as the `recall_prefs`
/// `user_settings` row (and mirrored locally for offline use). Parsing is
/// deliberately tolerant: unknown keys are ignored, missing fields fall back to
/// the historical defaults (limit 20, retention 0.9, oldest-first), and every
/// numeric value is clamped to a sane range.
class RecallPrefs {
  /// Default daily new-card limit (the old hardcoded `RecallApi.fetchQueue`
  /// constant).
  static const int defaultNewLimit = 20;
  static const double defaultRetention = 0.9;

  /// FSRS accepts 0.70–0.97; the slider and parser both clamp to this band.
  static const double minRetention = 0.70;
  static const double maxRetention = 0.97;
  static const int maxNewLimit = 999;

  final int newLimitDefault;
  final double desiredRetention;
  final NewOrder newOrder;

  /// deckId → per-deck new-card limit override.
  final Map<int, int> perDeck;

  const RecallPrefs({
    this.newLimitDefault = defaultNewLimit,
    this.desiredRetention = defaultRetention,
    this.newOrder = NewOrder.oldestFirst,
    this.perDeck = const {},
  });

  /// The effective new-card limit for a deck: its override if set, else the
  /// default. `null` deck (all-decks study) always uses the default.
  int newLimitForDeck(int? deckId) {
    if (deckId != null) {
      final override = perDeck[deckId];
      if (override != null) return override;
    }
    return newLimitDefault;
  }

  RecallPrefs copyWith({
    int? newLimitDefault,
    double? desiredRetention,
    NewOrder? newOrder,
    Map<int, int>? perDeck,
  }) {
    return RecallPrefs(
      newLimitDefault: newLimitDefault ?? this.newLimitDefault,
      desiredRetention: desiredRetention ?? this.desiredRetention,
      newOrder: newOrder ?? this.newOrder,
      perDeck: perDeck ?? this.perDeck,
    );
  }

  /// Whether the fields that shape the study queue (limit, order, per-deck
  /// overrides) are unchanged — retention differences don't require a reload.
  bool sameQueueShape(RecallPrefs other) =>
      newLimitDefault == other.newLimitDefault &&
      newOrder == other.newOrder &&
      _mapEquals(perDeck, other.perDeck);

  /// Set (or, with a null limit, clear) a per-deck override.
  RecallPrefs withDeckOverride(int deckId, int? limit) {
    final next = Map<int, int>.from(perDeck);
    if (limit == null) {
      next.remove(deckId);
    } else {
      next[deckId] = limit.clamp(0, maxNewLimit);
    }
    return copyWith(perDeck: next);
  }

  static int _clampLimit(Object? v) {
    if (v is num) return v.toInt().clamp(0, maxNewLimit);
    return defaultNewLimit;
  }

  factory RecallPrefs.fromJson(Object? raw) {
    if (raw is! Map) return const RecallPrefs();
    final json = Map<String, dynamic>.from(raw);

    final retention = json['desired_retention'];
    final perDeckRaw = json['per_deck'];
    final perDeck = <int, int>{};
    if (perDeckRaw is Map) {
      perDeckRaw.forEach((key, value) {
        final deckId = key is int ? key : int.tryParse('$key');
        if (deckId == null) return;
        if (value is Map && value['new_limit'] != null) {
          perDeck[deckId] = _clampLimit(value['new_limit']);
        } else if (value is num) {
          // Tolerate a bare number as the override too.
          perDeck[deckId] = _clampLimit(value);
        }
      });
    }

    return RecallPrefs(
      newLimitDefault: json.containsKey('new_limit_default')
          ? _clampLimit(json['new_limit_default'])
          : defaultNewLimit,
      desiredRetention: retention is num
          ? retention.toDouble().clamp(minRetention, maxRetention)
          : defaultRetention,
      newOrder: NewOrder.fromKey(json['new_order']),
      perDeck: perDeck,
    );
  }

  Map<String, dynamic> toJson() => {
    'new_limit_default': newLimitDefault,
    'desired_retention': desiredRetention,
    'new_order': newOrder.key,
    'per_deck': {
      for (final entry in perDeck.entries)
        '${entry.key}': {'new_limit': entry.value},
    },
  };

  @override
  bool operator ==(Object other) =>
      other is RecallPrefs &&
      other.newLimitDefault == newLimitDefault &&
      other.desiredRetention == desiredRetention &&
      other.newOrder == newOrder &&
      _mapEquals(other.perDeck, perDeck);

  @override
  int get hashCode => Object.hash(
    newLimitDefault,
    desiredRetention,
    newOrder,
    Object.hashAllUnordered([
      for (final e in perDeck.entries) Object.hash(e.key, e.value),
    ]),
  );
}

bool _mapEquals(Map<int, int> a, Map<int, int> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

/// A deterministic per-(day, deck) seed so a `random` new-order stays stable
/// when the user re-enters the study tab mid-day. Derived from the local date
/// string + deck so it changes at the local day boundary, never from a
/// build-time random.
int newOrderDaySeed(DateTime day, int? deckId) {
  final key = '${day.year}-${day.month}-${day.day}:${deckId ?? 'all'}';
  return key.hashCode & 0x7fffffff;
}

/// Deterministic Fisher–Yates shuffle: the same [seed] always produces the same
/// order for the same input, so the queue is stable within a local day.
List<T> seededShuffle<T>(List<T> items, int seed) {
  final out = List<T>.from(items);
  final rng = math.Random(seed);
  for (var i = out.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

/// FSRS rule-of-thumb: review workload scales roughly with the inverse of the
/// forgetting allowance, normalised to ×1.0 at the 0.9 baseline. Used only for
/// the settings slider's live "≈ workload ×N" hint.
double retentionWorkloadMultiplier(double retention) {
  final r = retention.clamp(RecallPrefs.minRetention, RecallPrefs.maxRetention);
  return (1 - RecallPrefs.defaultRetention) / (1 - r);
}

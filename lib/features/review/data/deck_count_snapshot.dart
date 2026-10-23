import 'dart:convert';

/// A server baseline plus the cards whose acknowledged reviews it now covers.
/// Coverage survives a failed refresh and prevents an ACK retry subtracting twice.
class DeckCountSnapshot {
  DeckCountSnapshot(this.counts, this.fetchedAt, [Set<int>? settled])
    : settled = settled ?? <int>{};

  final Map<int, ({int due, int neu})> counts;
  final DateTime fetchedAt;
  final Set<int> settled;

  static DeckCountSnapshot? decode(String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // Older caches may already include an ambiguous pending upload.
      if (data['version'] != 2) return null;
      final rows = data['counts'] as Map<String, dynamic>;
      return DeckCountSnapshot(
        {
          for (final entry in rows.entries)
            int.parse(entry.key): (
              due: (entry.value['due'] as num).toInt(),
              neu: (entry.value['new'] as num).toInt(),
            ),
        },
        DateTime.parse(data['fetchedAt'] as String),
        {...(data['settled'] as List? ?? const []).cast<int>()},
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({
    'version': 2,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'counts': {
      for (final entry in counts.entries)
        '${entry.key}': {'due': entry.value.due, 'new': entry.value.neu},
    },
    'settled': settled.toList()..sort(),
  });

  /// Apply each card once, using its original bucket at the baseline's time.
  /// Legacy entries without metadata cannot safely be assigned a bucket.
  void subtract(Iterable<Map<String, dynamic>> reviews) {
    for (final entry in reviews) {
      final cardId = entry['card_id'];
      final deckId = entry['deck_id'];
      final state = entry['previous_state'];
      if (cardId is! int || deckId is! int || state is! int) continue;
      final count = counts[deckId];
      if (count == null || !settled.add(cardId)) continue;
      final rawDue = entry['previous_due'];
      final due = rawDue is String ? DateTime.tryParse(rawDue) : null;
      counts[deckId] = (
        due: state != 0 && due != null && !due.isAfter(fetchedAt)
            ? (count.due - 1).clamp(0, count.due)
            : count.due,
        neu: state == 0 ? (count.neu - 1).clamp(0, count.neu) : count.neu,
      );
    }
  }
}

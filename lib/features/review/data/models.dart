// Plain data rows mirroring the Supabase schema (see ANKI_WEB_PLAN.md §3).

class DeckRow {
  final int deckId;
  final String name;
  const DeckRow({required this.deckId, required this.name});

  factory DeckRow.fromMap(Map<String, dynamic> m) => DeckRow(
    deckId: (m['deck_id'] as num).toInt(),
    name: (m['name'] as String?) ?? 'Deck',
  );

  Map<String, dynamic> toJson() => {'deck_id': deckId, 'name': name};
  factory DeckRow.fromJson(Map<String, dynamic> m) => DeckRow.fromMap(m);
}

class FsrsSettings {
  final List<double> parameters;
  final double desiredRetention;

  const FsrsSettings({required this.parameters, this.desiredRetention = 0.9});

  static FsrsSettings? tryParse(Object? value) {
    if (value is! Map) return null;
    final data = Map<String, dynamic>.from(value);
    final rawParameters = data['parameters'] ?? data['weights'];
    if (rawParameters is! List || rawParameters.length != 21) return null;
    final rawRetention =
        data['desired_retention'] ??
        data['desiredRetention'] ??
        data['requestRetention'];
    final parameters = <double>[];
    for (final v in rawParameters) {
      if (v is! num) return null;
      parameters.add(v.toDouble());
    }
    return FsrsSettings(
      parameters: parameters,
      desiredRetention: rawRetention is num ? rawRetention.toDouble() : 0.9,
    );
  }
}

/// A card joined to its note content. `state`: 0=new 1=learning 2=review
/// 3=relearning (Anki/FSRS convention).
class ReviewCard {
  final int id;
  final String guid;
  final int deckId;
  final String front;
  final String back;
  final bool hasLatex;
  final double? stability;
  final double? difficulty;
  final DateTime? due;
  final int state;
  final int reps;
  final int lapses;
  final DateTime? lastReview;

  /// Server-side rendered SVG for display (block) LaTeX the client can't render
  /// inline. Empty in practice (the pipeline never populated it), so treated as
  /// an optional fallback — see [CardFace]. Extracted to raw `<svg …>` markup.
  final String? latexSvg;

  const ReviewCard({
    required this.id,
    required this.guid,
    required this.deckId,
    required this.front,
    required this.back,
    required this.hasLatex,
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.state,
    required this.reps,
    required this.lapses,
    required this.lastReview,
    this.latexSvg,
  });

  bool get isNew => state == 0;

  factory ReviewCard.fromRow(Map<String, dynamic> m) {
    final note = (m['notes'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ReviewCard(
      id: (m['id'] as num).toInt(),
      guid: m['guid'] as String,
      deckId: (note['deck_id'] as num?)?.toInt() ?? 0,
      front: (note['front'] as String?) ?? '',
      back: (note['back'] as String?) ?? '',
      hasLatex: (note['has_latex'] as bool?) ?? false,
      stability: (m['stability'] as num?)?.toDouble(),
      difficulty: (m['difficulty'] as num?)?.toDouble(),
      due: _parseTs(m['due']),
      state: (m['state'] as num?)?.toInt() ?? 0,
      reps: (m['reps'] as num?)?.toInt() ?? 0,
      lapses: (m['lapses'] as num?)?.toInt() ?? 0,
      lastReview: _parseTs(m['last_review']),
      latexSvg: _svgString(note['latex_svg']),
    );
  }

  /// Flat JSON for the offline snapshot cache (no nested `notes`).
  Map<String, dynamic> toJson() => {
    'id': id,
    'guid': guid,
    'deck_id': deckId,
    'front': front,
    'back': back,
    'has_latex': hasLatex,
    'stability': stability,
    'difficulty': difficulty,
    'due': due?.toIso8601String(),
    'state': state,
    'reps': reps,
    'lapses': lapses,
    'last_review': lastReview?.toIso8601String(),
    if (latexSvg != null) 'latex_svg': latexSvg,
  };

  factory ReviewCard.fromJson(Map<String, dynamic> m) => ReviewCard(
    id: (m['id'] as num).toInt(),
    guid: m['guid'] as String,
    deckId: (m['deck_id'] as num?)?.toInt() ?? 0,
    front: (m['front'] as String?) ?? '',
    back: (m['back'] as String?) ?? '',
    hasLatex: (m['has_latex'] as bool?) ?? false,
    stability: (m['stability'] as num?)?.toDouble(),
    difficulty: (m['difficulty'] as num?)?.toDouble(),
    due: _parseTs(m['due']),
    state: (m['state'] as num?)?.toInt() ?? 0,
    reps: (m['reps'] as num?)?.toInt() ?? 0,
    lapses: (m['lapses'] as num?)?.toInt() ?? 0,
    lastReview: _parseTs(m['last_review']),
    // Tolerant: snapshots written before this field simply omit the key.
    latexSvg: m['latex_svg'] as String?,
  );
}

/// Result of scheduling a card with FSRS — the columns to persist.
class ReviewOutcome {
  final double stability;
  final double difficulty;
  final DateTime due;
  final int state;
  final int reps;
  final int lapses;
  final DateTime reviewedAt;
  final int rating;

  const ReviewOutcome({
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.state,
    required this.reps,
    required this.lapses,
    required this.reviewedAt,
    required this.rating,
  });
}

DateTime? _parseTs(dynamic v) =>
    v == null ? null : DateTime.parse(v as String).toUtc();

/// The `latex_svg` column is `jsonb` and, in practice, always null. Defensively
/// pull the first `<svg …>` string out of whatever shape it holds (a raw
/// string, or a map/list of per-field SVGs) so a future population can't crash
/// the client; returns null when there's nothing SVG-shaped to render.
String? _svgString(dynamic v) {
  if (v is String) {
    return v.trimLeft().startsWith('<svg') ? v : null;
  }
  if (v is Map) {
    for (final value in v.values) {
      final s = _svgString(value);
      if (s != null) return s;
    }
  }
  if (v is List) {
    for (final value in v) {
      final s = _svgString(value);
      if (s != null) return s;
    }
  }
  return null;
}

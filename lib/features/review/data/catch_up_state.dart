/// The only durable state owned by the optional backlog catch-up presentation.
/// It is deliberately separate from [RecallPrefs]: those preferences are
/// mirrored to Supabase, while catch-up opt-in and progress must stay local.
enum CatchUpMode { none, active, dismissed }

class CatchUpLocalState {
  static const none = CatchUpLocalState();

  final CatchUpMode mode;
  final String? dayKey;
  final int completedToday;

  /// The study stream (all decks or one selected deck) whose backlog the
  /// learner opted into or dismissed. Only that stream can end the episode;
  /// a small or new-only deck opened meanwhile says nothing about it. Null for
  /// state saved before streams were recorded, which every stream may end.
  final String? deckStream;

  const CatchUpLocalState({
    this.mode = CatchUpMode.none,
    this.dayKey,
    this.completedToday = 0,
    this.deckStream,
  });

  static String streamFor(int? deckId) =>
      deckId == null ? 'all' : 'deck:$deckId';

  bool coversStream(String stream) =>
      deckStream == null || deckStream == stream;

  CatchUpLocalState copyWith({
    CatchUpMode? mode,
    String? dayKey,
    int? completedToday,
    String? deckStream,
  }) => CatchUpLocalState(
    mode: mode ?? this.mode,
    dayKey: dayKey ?? this.dayKey,
    completedToday: completedToday ?? this.completedToday,
    deckStream: deckStream ?? this.deckStream,
  );

  factory CatchUpLocalState.fromJson(Object? raw) {
    if (raw is! Map) return none;
    final mode = switch (raw['mode']) {
      'active' => CatchUpMode.active,
      'dismissed' => CatchUpMode.dismissed,
      _ => CatchUpMode.none,
    };
    final completed = raw['completed_today'];
    final stream = raw['deck_stream'];
    return CatchUpLocalState(
      mode: mode,
      dayKey: raw['day'] as String?,
      completedToday: completed is num ? completed.toInt().clamp(0, 999999) : 0,
      deckStream: stream is String ? stream : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (dayKey != null) 'day': dayKey,
    'completed_today': completedToday,
    if (deckStream != null) 'deck_stream': deckStream,
  };

  @override
  bool operator ==(Object other) =>
      other is CatchUpLocalState &&
      other.mode == mode &&
      other.dayKey == dayKey &&
      other.completedToday == completedToday &&
      other.deckStream == deckStream;

  @override
  int get hashCode => Object.hash(mode, dayKey, completedToday, deckStream);
}

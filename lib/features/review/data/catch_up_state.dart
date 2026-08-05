/// The only durable state owned by the optional backlog catch-up presentation.
/// It is deliberately separate from [RecallPrefs]: those preferences are
/// mirrored to Supabase, while catch-up opt-in and progress must stay local.
enum CatchUpMode { none, active, dismissed }

class CatchUpLocalState {
  static const none = CatchUpLocalState();

  final CatchUpMode mode;
  final String? dayKey;
  final int completedToday;

  const CatchUpLocalState({
    this.mode = CatchUpMode.none,
    this.dayKey,
    this.completedToday = 0,
  });

  CatchUpLocalState copyWith({
    CatchUpMode? mode,
    String? dayKey,
    int? completedToday,
  }) => CatchUpLocalState(
    mode: mode ?? this.mode,
    dayKey: dayKey ?? this.dayKey,
    completedToday: completedToday ?? this.completedToday,
  );

  factory CatchUpLocalState.fromJson(Object? raw) {
    if (raw is! Map) return none;
    final mode = switch (raw['mode']) {
      'active' => CatchUpMode.active,
      'dismissed' => CatchUpMode.dismissed,
      _ => CatchUpMode.none,
    };
    final completed = raw['completed_today'];
    return CatchUpLocalState(
      mode: mode,
      dayKey: raw['day'] as String?,
      completedToday: completed is num ? completed.toInt().clamp(0, 999999) : 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (dayKey != null) 'day': dayKey,
    'completed_today': completedToday,
  };

  @override
  bool operator ==(Object other) =>
      other is CatchUpLocalState &&
      other.mode == mode &&
      other.dayKey == dayKey &&
      other.completedToday == completedToday;

  @override
  int get hashCode => Object.hash(mode, dayKey, completedToday);
}

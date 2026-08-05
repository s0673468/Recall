import 'dart:math' as math;

import '../data/catch_up_state.dart';
import '../data/models.dart';
import '../domain/stats_models.dart';
import 'fsrs_engine.dart';

/// Pure rules for the optional backlog presentation. The server queue remains
/// the source list; these helpers only rank and slice the cards already read.
class BacklogCatchUp {
  static const int recentDays = 14;
  static const int thresholdFloor = 80;
  static const int dailyCap = 20;

  static double recentDailyAverage(
    Iterable<ReviewLogEntry> reviews, {
    required DateTime now,
  }) {
    final today = dayOnly(now);
    final cutoff = today.subtract(const Duration(days: recentDays - 1));
    var count = 0;
    for (final review in reviews) {
      final day = dayOnly(review.at);
      if (day.isBefore(cutoff) || day.isAfter(today)) continue;
      count++;
    }
    return count / recentDays;
  }

  static int thresholdForAverage(double recentDailyAverage) =>
      math.max(thresholdFloor, (recentDailyAverage * 2).ceil());

  static bool isEligible({
    required int dueCount,
    required double recentDailyAverage,
  }) => dueCount > thresholdForAverage(recentDailyAverage);

  /// Ranks only existing due cards. Ties retain their fetched order so the
  /// presentation remains deterministic when two cards have equal FSRS values.
  static List<ReviewCard> orderDue(
    Iterable<ReviewCard> cards,
    FsrsEngine engine, {
    required DateTime now,
  }) {
    final ranked = [
      for (var index = 0; index < cards.length; index++)
        if (!cards.elementAt(index).isNew)
          (
            card: cards.elementAt(index),
            index: index,
            retrievability: engine.retrievability(
              cards.elementAt(index),
              now: now,
            ),
          ),
    ];
    ranked.sort((a, b) {
      final byRetrievability = a.retrievability.compareTo(b.retrievability);
      return byRetrievability == 0
          ? a.index.compareTo(b.index)
          : byRetrievability;
    });
    return [for (final item in ranked) item.card];
  }

  static List<ReviewCard> takeForToday(
    List<ReviewCard> orderedDue, {
    required int completedToday,
  }) {
    final remaining = math.max(0, dailyCap - completedToday);
    return orderedDue.take(remaining).toList();
  }

  static int estimatedDays(int dueCount) {
    if (dueCount <= 0) return 0;
    return (dueCount + dailyCap - 1) ~/ dailyCap;
  }

  static String dayKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static CatchUpLocalState normalizeLocalState(
    CatchUpLocalState state,
    DateTime now,
  ) {
    final today = dayKey(now);
    if (state.dayKey == today) return state;
    return CatchUpLocalState(mode: state.mode, dayKey: today);
  }

  static DateTime dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

/// Presentation metadata exposed to the study screen. It contains no server
/// or scheduling state and is rebuilt from the fetched queue on every load.
class CatchUpView {
  final CatchUpMode mode;
  final int dueCount;
  final int threshold;
  final double recentDailyAverage;
  final int completedToday;
  final int dailyCap;

  const CatchUpView({
    this.mode = CatchUpMode.none,
    this.dueCount = 0,
    this.threshold = BacklogCatchUp.thresholdFloor,
    this.recentDailyAverage = 0,
    this.completedToday = 0,
    this.dailyCap = BacklogCatchUp.dailyCap,
  });

  bool get isNone => mode == CatchUpMode.none;
  bool get isActive => mode == CatchUpMode.active;
  bool get isDismissed => mode == CatchUpMode.dismissed;
  bool get isEligible => dueCount > threshold;
  bool get shouldOffer => isNone && isEligible;
  int get remainingToday => math.max(0, dailyCap - completedToday);
  int get estimatedDays => BacklogCatchUp.estimatedDays(dueCount);

  String get planLine =>
      '$dailyCap cards/day · about $estimatedDays '
      '${estimatedDays == 1 ? 'day' : 'days'}';

  CatchUpView copyWith({
    CatchUpMode? mode,
    int? dueCount,
    int? threshold,
    double? recentDailyAverage,
    int? completedToday,
    int? dailyCap,
  }) => CatchUpView(
    mode: mode ?? this.mode,
    dueCount: dueCount ?? this.dueCount,
    threshold: threshold ?? this.threshold,
    recentDailyAverage: recentDailyAverage ?? this.recentDailyAverage,
    completedToday: completedToday ?? this.completedToday,
    dailyCap: dailyCap ?? this.dailyCap,
  );

  @override
  bool operator ==(Object other) =>
      other is CatchUpView &&
      other.mode == mode &&
      other.dueCount == dueCount &&
      other.threshold == threshold &&
      other.recentDailyAverage == recentDailyAverage &&
      other.completedToday == completedToday &&
      other.dailyCap == dailyCap;

  @override
  int get hashCode => Object.hash(
    mode,
    dueCount,
    threshold,
    recentDailyAverage,
    completedToday,
    dailyCap,
  );
}

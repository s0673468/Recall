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

  /// [localDate] builds local midnight from wall-clock fields; tests inject a
  /// fixed zone. The window is [recentDays] calendar days ending today.
  static double recentDailyAverage(
    Iterable<ReviewLogEntry> reviews, {
    required DateTime now,
    DateTime Function(int year, int month, int day) localDate = DateTime.new,
  }) {
    final today = localDate(now.year, now.month, now.day);
    // Calendar arithmetic: a fixed Duration is 24-hour days and shifts the
    // cutoff by the DST hour for two weeks after each transition.
    final cutoff = localDate(now.year, now.month, now.day - (recentDays - 1));
    var count = 0;
    for (final review in reviews) {
      final at = review.at;
      final day = localDate(at.year, at.month, at.day);
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
    final ranked = _rankDue(cards, engine, now: now).toList();
    ranked.sort(_compareRank);
    return [for (final item in ranked) item.card];
  }

  /// Select the same prefix as orderDue + takeForToday without allocating and
  /// sorting the entire backlog. Only the remaining daily ranks are retained.
  /// Equal retrievability keeps fetched order, including ties at the cutoff.
  static List<ReviewCard> takeDueForToday(
    Iterable<ReviewCard> cards,
    FsrsEngine engine, {
    required DateTime now,
    required int completedToday,
  }) {
    final limit = math.max(0, dailyCap - completedToday);
    if (limit == 0) return [];
    final best = <_DueRank>[];
    for (final rank in _rankDue(cards, engine, now: now)) {
      if (best.length == limit && _compareRank(rank, best.last) >= 0) {
        continue;
      }
      var low = 0;
      var high = best.length;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (_compareRank(best[mid], rank) <= 0) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      best.insert(low, rank);
      if (best.length > limit) best.removeLast();
    }
    return [for (final rank in best) rank.card];
  }

  static Iterable<_DueRank> _rankDue(
    Iterable<ReviewCard> cards,
    FsrsEngine engine, {
    required DateTime now,
  }) sync* {
    var index = 0;
    for (final card in cards) {
      if (!card.isNew) {
        yield (
          card: card,
          index: index,
          retrievability: engine.retrievability(card, now: now),
        );
      }
      index++;
    }
  }

  static int _compareRank(_DueRank a, _DueRank b) {
    final byRetrievability = a.retrievability.compareTo(b.retrievability);
    return byRetrievability == 0
        ? a.index.compareTo(b.index)
        : byRetrievability;
  }

  static List<ReviewCard> takeForToday(
    List<ReviewCard> orderedDue, {
    required int completedToday,
  }) {
    final remaining = math.max(0, dailyCap - completedToday);
    return orderedDue.take(remaining).toList();
  }

  /// Calendar days needed from now, using only the unused part of today's
  /// allowance before counting full future days.
  static int estimatedDays(
    int dueCount, {
    int completedToday = 0,
    int dailyLimit = dailyCap,
  }) {
    if (dueCount <= 0) return 0;
    if (dailyLimit <= 0) {
      throw ArgumentError.value(dailyLimit, 'dailyLimit', 'must be positive');
    }
    final remainingToday = math.max(
      0,
      dailyLimit - math.max(0, completedToday),
    );
    final afterToday = math.max(0, dueCount - remainingToday);
    final futureDays = (afterToday + dailyLimit - 1) ~/ dailyLimit;
    return (remainingToday > 0 ? 1 : 0) + futureDays;
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
    return CatchUpLocalState(
      mode: state.mode,
      dayKey: today,
      deckStream: state.deckStream,
    );
  }

  static DateTime dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

typedef _DueRank = ({ReviewCard card, int index, double retrievability});

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
  int get estimatedDays => BacklogCatchUp.estimatedDays(
    dueCount,
    completedToday: completedToday,
    dailyLimit: dailyCap,
  );

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

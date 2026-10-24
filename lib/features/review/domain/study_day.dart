/// Recall study days reset at midnight America/Sao_Paulo (UTC−03:00).
/// Brazil has had no daylight saving since 2019. Use UTC instants throughout,
/// never the device zone; keep this rule aligned with Recall Hub.
class StudyDay {
  static const resetDescription =
      'Daily counts and new-card limits reset at midnight America/Sao_Paulo (UTC−03:00).';
  static const _offset = Duration(hours: 3);

  static DateTime start(DateTime instant) {
    final wall = instant.toUtc().subtract(_offset);
    return DateTime.utc(wall.year, wall.month, wall.day).add(_offset);
  }

  static DateTime end(DateTime instant) =>
      start(instant).add(const Duration(days: 1));

  static bool contains(DateTime at, DateTime now) =>
      !at.isBefore(start(now)) && at.isBefore(end(now));
}

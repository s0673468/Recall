/// Truncates local timestamps to their local calendar day, memoized for one
/// pass over a review log.
///
/// `DateTime(year, month, day)` resolves the device time zone on every call,
/// which dominates the Stats and Read transforms on a long log. A log spans a
/// few hundred distinct days, so each day is constructed once and reused. The
/// result is exactly `DateTime(value.year, value.month, value.day)`.
final class LocalDayMemo {
  final _days = <int, DateTime>{};

  DateTime call(DateTime value) {
    final year = value.year;
    final month = value.month;
    final day = value.day;
    return _days[(year * 100 + month) * 100 + day] ??= DateTime(
      year,
      month,
      day,
    );
  }
}

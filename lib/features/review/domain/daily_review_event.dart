import 'stats_models.dart';

/// Only rated review events enter the daily count. Flags/likes use another
/// outbox and have no review rating. Persist identities, never card content.
class DailyReviewEvent {
  final String key;
  final DateTime at;
  final bool awaitingHistory;

  const DailyReviewEvent(this.key, this.at, {this.awaitingHistory = false});

  DailyReviewEvent get receipt =>
      DailyReviewEvent(key, at, awaitingHistory: true);

  static String _key(
    Object? eventId,
    Object? cardId,
    DateTime at,
    String? device, {
    int? logId,
  }) => eventId != null
      ? 'event:$eventId'
      : device != null
      ? 'legacy:$cardId:${at.toUtc().toIso8601String()}:$device'
      : 'row:${logId ?? '$cardId:${at.toUtc().toIso8601String()}'}';

  static DailyReviewEvent? fromLog(ReviewLogEntry row) =>
      row.rating < 1 || row.rating > 4
      ? null
      : DailyReviewEvent(
          _key(
            row.clientEventId,
            row.cardId,
            row.at,
            row.device,
            logId: row.id,
          ),
          row.at.toUtc(),
        );

  static DailyReviewEvent? fromPending(Map<String, dynamic> row) {
    final rating = row['rating'];
    final raw = row['last_review'];
    if (rating is! int || rating < 1 || rating > 4 || raw is! String) {
      return null;
    }
    final at = DateTime.tryParse(raw)?.toUtc();
    if (at == null) return null;
    return DailyReviewEvent(
      _key(row['client_id'], row['card_id'], at, row['device'] as String?),
      at,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'at': at.toIso8601String(),
    'receipt': awaitingHistory,
  };

  static DailyReviewEvent? decode(Map<String, dynamic> row) {
    final key = row['key'];
    final raw = row['at'];
    final at = raw is String ? DateTime.tryParse(raw) : null;
    return key is String && at != null
        ? DailyReviewEvent(
            key,
            at.toUtc(),
            awaitingHistory: row['receipt'] == true,
          )
        : null;
  }
}

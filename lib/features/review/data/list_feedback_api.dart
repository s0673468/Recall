import 'recall_api.dart';

/// List-only metadata reads, separate from the review API contract.
extension ListFeedbackReads on RecallApi {
  /// Metadata only, shared by all rows in a reading/library load. Pagination
  /// follows flag IDs because multiple flags may refer to the same card.
  Future<List<Map<String, dynamic>>> fetchListFeedbackFlags() async {
    final flags = <Map<String, dynamic>>[];
    int? afterId;
    while (true) {
      var query = client
          .from('note_flags')
          .select('id,card_id,guid,reason,client_event_id')
          .eq('status', 'open')
          .inFilter('reason', const ['like', 'dislike']);
      if (afterId != null) query = query.gt('id', afterId);
      final page = await query.order('id', ascending: true).limit(500);
      if (page.isEmpty) return flags;
      final nextId = (page.last['id'] as num).toInt();
      if (afterId != null && nextId <= afterId) {
        throw StateError('List-feedback pagination did not advance');
      }
      flags.addAll([
        for (final row in page)
          {
            'card_id': row['card_id'],
            'guid': row['guid'],
            'reason': row['reason'],
            'client_id': row['client_event_id'],
          },
      ]);
      afterId = nextId;
    }
  }
}

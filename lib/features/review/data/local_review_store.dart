import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// On-device persistence so Recall opens instantly and works offline:
///  - a snapshot of the last-loaded decks + study queue, and
///  - an append-only outbox of reviews done while offline (or that failed to
///    sync), flushed to Supabase on the next launch/foreground.
///
/// Supabase remains the source of truth; this cache is disposable.
class LocalReviewStore {
  static const _snapshotKey = 'recall_snapshot_v1';
  static const _outboxKey = 'recall_outbox_v1';

  Future<void> saveSnapshot({
    required List<DeckRow> decks,
    required List<ReviewCard> queue,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _snapshotKey,
      jsonEncode({
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'decks': [for (final d in decks) d.toJson()],
        'queue': [for (final c in queue) c.toJson()],
      }),
    );
  }

  Future<({List<DeckRow> decks, List<ReviewCard> queue})?> loadSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_snapshotKey);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        decks: [
          for (final d in (m['decks'] as List))
            DeckRow.fromJson(Map<String, dynamic>.from(d as Map)),
        ],
        queue: [
          for (final c in (m['queue'] as List))
            ReviewCard.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> enqueueReview(Map<String, dynamic> entry) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _readOutbox(prefs)..add(entry);
    await prefs.setString(_outboxKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> outbox() async {
    final prefs = await SharedPreferences.getInstance();
    return _readOutbox(prefs);
  }

  Future<void> replaceOutbox(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_outboxKey, jsonEncode(items));
  }

  List<Map<String, dynamic>> _readOutbox(SharedPreferences prefs) {
    final raw = prefs.getString(_outboxKey);
    if (raw == null) return [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List))
          Map<String, dynamic>.from(e as Map),
      ];
    } catch (_) {
      return [];
    }
  }
}

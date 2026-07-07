import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// All Supabase reads/writes for Recall. RLS scopes every row to the signed-in
/// user, so no explicit user_id filter is needed.
class RecallApi {
  final SupabaseClient client;
  const RecallApi(this.client);

  static const _cardSelect =
      'id,guid,stability,difficulty,due,state,reps,lapses,last_review,'
      'notes!inner(front,back,has_latex,deck_id,latex_svg)';

  String get device => kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.android => 'android',
          _ => 'desktop',
        };

  // --- Auth ---
  User? get currentUser => client.auth.currentUser;
  Stream<AuthState> get onAuthStateChange => client.auth.onAuthStateChange;
  Future<void> signIn({required String email, required String password}) =>
      client.auth.signInWithPassword(email: email, password: password);
  Future<void> signOut() => client.auth.signOut();

  Future<List<DeckRow>> fetchDecks() async {
    final rows = await client
        .from('decks')
        .select('deck_id,name')
        .eq('deleted', false)
        .order('name');
    return [
      for (final r in rows) DeckRow.fromMap(Map<String, dynamic>.from(r)),
    ];
  }

  Future<FsrsSettings?> fetchFsrsSettings() async {
    final row = await client
        .from('user_settings')
        .select('settings_value')
        .eq('settings_key', 'fsrs_params')
        .maybeSingle();
    return FsrsSettings.tryParse(row?['settings_value']);
  }

  /// The study queue: every due review/learning card (due <= now), then up to
  /// [newLimit] new cards. Optionally restricted to one deck.
  Future<List<ReviewCard>> fetchQueue({int? deckId, int newLimit = 20}) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();

    PostgrestFilterBuilder<List<Map<String, dynamic>>> dueQ = client
        .from('cards')
        .select(_cardSelect)
        .eq('deleted', false)
        .neq('state', 0)
        .lte('due', nowIso);
    PostgrestFilterBuilder<List<Map<String, dynamic>>> newQ = client
        .from('cards')
        .select(_cardSelect)
        .eq('deleted', false)
        .eq('state', 0);

    if (deckId != null) {
      dueQ = dueQ.eq('notes.deck_id', deckId);
      newQ = newQ.eq('notes.deck_id', deckId);
    }

    final results = await Future.wait<List<Map<String, dynamic>>>([
      dueQ.order('due', ascending: true).limit(500),
      newQ.order('id', ascending: true).limit(newLimit),
    ]);
    final dueRows = results[0];
    final newRows = results[1];

    return [
      for (final r in dueRows) ReviewCard.fromRow(Map<String, dynamic>.from(r)),
      for (final r in newRows) ReviewCard.fromRow(Map<String, dynamic>.from(r)),
    ];
  }

  /// A self-contained, JSON-serializable record of one review — what the outbox
  /// stores and replays. Built locally so a review survives an offline session.
  Map<String, dynamic> reviewEntry(ReviewCard card, ReviewOutcome o) => {
    'card_id': card.id,
    'guid': card.guid,
    'stability': o.stability,
    'difficulty': o.difficulty,
    'due': o.due.toIso8601String(),
    'state': o.state,
    'reps': o.reps,
    'lapses': o.lapses,
    'last_review': o.reviewedAt.toIso8601String(),
    'rating': o.rating,
    'device': device,
  };

  /// Replay one review entry against Supabase: advance the card's FSRS state and
  /// append an immutable log row.
  Future<void> applyReview(Map<String, dynamic> e) async {
    await client
        .from('cards')
        .update({
          'stability': e['stability'],
          'difficulty': e['difficulty'],
          'due': e['due'],
          'state': e['state'],
          'reps': e['reps'],
          'lapses': e['lapses'],
          'last_review': e['last_review'],
          'cloud_seen': true,
        })
        .eq('id', e['card_id']);

    await client.from('review_log').insert({
      'card_id': e['card_id'],
      'guid': e['guid'],
      'rating': e['rating'],
      'rating_at': e['last_review'],
      'stability_after': e['stability'],
      'difficulty_after': e['difficulty'],
      'due_after': e['due'],
      'state_after': e['state'],
      'device': e['device'],
    });
  }

  /// Recent reviews (local timestamp + 1-4 rating) for the stats screen.
  Future<List<({DateTime at, int rating})>> fetchRecentReviews({
    int days = 30,
  }) async {
    final since = DateTime.now()
        .toUtc()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows = await client
        .from('review_log')
        .select('rating_at,rating')
        .gte('rating_at', since)
        .order('rating_at', ascending: true);
    return [
      for (final r in rows)
        (
          at: DateTime.parse(r['rating_at'] as String).toLocal(),
          rating: (r['rating'] as num).toInt(),
        ),
    ];
  }

  /// Per-deck due/new counts via the deck_counts() RPC.
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async {
    final res = await client.rpc('deck_counts');
    final rows = (res as List).cast<Map<String, dynamic>>();
    return {
      for (final r in rows)
        (r['deck_id'] as num).toInt(): (
          due: (r['due'] as num?)?.toInt() ?? 0,
          neu: (r['new'] as num?)?.toInt() ?? 0,
        ),
    };
  }
}

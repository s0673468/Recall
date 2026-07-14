import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../settings/domain/recall_prefs.dart';
import '../domain/stats_models.dart';
import 'models.dart';

/// All Supabase reads/writes for Recall. RLS scopes every row to the signed-in
/// user, so no explicit user_id filter is needed.
class RecallApi {
  final SupabaseClient client;
  final Future<void> Function(String)? _persistSession;
  final Future<void> Function()? _removePersistedSession;

  const RecallApi(
    this.client, {
    Future<void> Function(String)? persistSession,
    Future<void> Function()? removePersistedSession,
  }) : _persistSession = persistSession,
       _removePersistedSession = removePersistedSession;

  static const _cardSelect =
      'id,guid,stability,difficulty,due,state,reps,lapses,last_review,'
      'cloud_seen,notes!inner(front,back,has_latex,deck_id,latex_svg)';

  String get device =>
      recallDeviceLabel(isWeb: kIsWeb, targetPlatform: defaultTargetPlatform);

  // --- Auth ---
  User? get currentUser => client.auth.currentUser;
  Stream<AuthState> get onAuthStateChange => client.auth.onAuthStateChange;
  Future<void> signIn({required String email, required String password}) async {
    final response = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final persistSession = _persistSession;
    if (persistSession == null) return;
    final session = response.session ?? client.auth.currentSession;
    if (session == null) {
      await client.auth.signOut();
      await _removePersistedSession?.call();
      throw StateError('Recall sign-in returned no session.');
    }
    try {
      await persistSession(jsonEncode(session.toJson()));
    } catch (_) {
      try {
        await client.auth.signOut();
      } finally {
        await _removePersistedSession?.call();
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await client.auth.signOut();
    } catch (error) {
      if (client.auth.currentSession != null) rethrow;
      // GoTrue can report a remote logout failure after it has already cleared
      // the local auth state. Complete that explicit user sign-out rather than
      // reporting a failure while leaving Recall visibly signed out.
      debugPrint(
        'Recall: remote sign-out failed after local session cleared; '
        'completing local sign-out: $error',
      );
    }
    await _removePersistedSession?.call();
  }

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

  /// Recall's study preferences row (new-card limit, retention, ordering).
  /// Returns null when the row is absent so the caller keeps its defaults.
  Future<Map<String, dynamic>?> fetchRecallPrefs() async {
    final row = await client
        .from('user_settings')
        .select('settings_value')
        .eq('settings_key', 'recall_prefs')
        .maybeSingle();
    final value = row?['settings_value'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  /// Write-through the study preferences. Relies on the same owner default
  /// user_id the review-log inserts use, and the (user_id, settings_key)
  /// unique constraint for the upsert.
  Future<void> saveRecallPrefs(Map<String, dynamic> value) async {
    await client.from('user_settings').upsert({
      'user_id': ?currentUser?.id,
      'settings_key': 'recall_prefs',
      'settings_value': value,
    }, onConflict: 'user_id,settings_key');
  }

  /// The study queue: every due review/learning card (due <= now), then up to
  /// [newLimit] new cards ordered per [order]. Optionally restricted to one
  /// deck. `random` shuffles the fetched new-card page with a per-(day, deck)
  /// seed so re-entering the tab mid-day keeps a stable order.
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();

    // Suspended cards (cards.suspended = true, set one-way by the desktop
    // importer) are dormant — never queued as due or new. Filtered server-side
    // so the payload never carries them.
    PostgrestFilterBuilder<List<Map<String, dynamic>>> dueQ = client
        .from('cards')
        .select(_cardSelect)
        .eq('deleted', false)
        .eq('suspended', false)
        .neq('state', 0)
        .lte('due', nowIso);
    PostgrestFilterBuilder<List<Map<String, dynamic>>> newQ = client
        .from('cards')
        .select(_cardSelect)
        .eq('deleted', false)
        .eq('suspended', false)
        .eq('state', 0);

    if (deckId != null) {
      dueQ = dueQ.eq('notes.deck_id', deckId);
      newQ = newQ.eq('notes.deck_id', deckId);
    }

    // newest_first inverts the id order; random still fetches a stable page
    // (id asc) and shuffles client-side so the same cards recur across loads.
    final newAscending = order != NewOrder.newestFirst;
    final results = await Future.wait<List<Map<String, dynamic>>>([
      dueQ.order('due', ascending: true).limit(500),
      newQ.order('id', ascending: newAscending).limit(newLimit),
    ]);
    final dueRows = results[0];
    final newRows = results[1];

    var newCards = [
      for (final r in newRows) ReviewCard.fromRow(Map<String, dynamic>.from(r)),
    ];
    if (order == NewOrder.random) {
      newCards = seededShuffle(
        newCards,
        newOrderDaySeed(DateTime.now(), deckId),
      );
    }

    return [
      for (final r in dueRows) ReviewCard.fromRow(Map<String, dynamic>.from(r)),
      ...newCards,
    ];
  }

  /// A self-contained, JSON-serializable record of one review — what the outbox
  /// stores and replays. Built locally so a review survives an offline session.
  /// [elapsedMs] is the time the card was on screen (front shown → rating
  /// tapped), measured at review time so an offline replay keeps the truth.
  Map<String, dynamic> reviewEntry(
    ReviewCard card,
    ReviewOutcome o, {
    int? elapsedMs,
  }) => {
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
    'elapsed_ms': elapsedMs,
    'device': device,
  };

  /// The pre-rating scheduling state of a card, shaped like [reviewEntry], so
  /// an undo can restore the cards row through the same update path a rating
  /// uses (see [undoReview]).
  Map<String, dynamic> restoreEntry(ReviewCard card) => {
    'card_id': card.id,
    'stability': card.stability,
    'difficulty': card.difficulty,
    'due': card.due?.toIso8601String(),
    'state': card.state,
    'reps': card.reps,
    'lapses': card.lapses,
    'last_review': card.lastReview?.toIso8601String(),
    'cloud_seen': card.cloudSeen,
  };

  /// Replay one review entry against Supabase: advance the card's FSRS state
  /// and append a log row. Returns the inserted review_log id so a later undo
  /// can target exactly this row.
  Future<int?> applyReview(Map<String, dynamic> e) async {
    final eventId = e['client_id']?.toString();
    if (eventId != null) {
      try {
        return await _applyReviewIdempotently(e, eventId);
      } on PostgrestException catch (error) {
        if (!_idempotencySchemaUnavailable(error)) rethrow;
        // Rolling-deploy compatibility only. Once the checked-in migration is
        // applied, every native review takes the server-enforced path above.
        debugPrint(
          'Recall: idempotency schema not deployed; using legacy replay',
        );
      }
    }
    return _applyReviewLegacy(e);
  }

  Future<int?> _applyReviewIdempotently(
    Map<String, dynamic> e,
    String eventId,
  ) async {
    final existing = await client
        .from('review_log')
        .select('id')
        .eq('card_id', e['card_id'])
        .eq('client_event_id', eventId)
        .limit(1);
    if (existing.isNotEmpty) {
      return (existing.first['id'] as num?)?.toInt();
    }

    await _updateCard(e);
    final inserted = await client
        .from('review_log')
        .upsert(
          _reviewLogPayload(e, clientEventId: eventId),
          onConflict: 'card_id,client_event_id',
        )
        .select('id')
        .single();
    return (inserted['id'] as num?)?.toInt();
  }

  Future<int?> _applyReviewLegacy(Map<String, dynamic> e) async {
    // The local outbox is at-least-once: a network response or the on-device
    // acknowledgement write can fail after Supabase committed the insert.
    // rating_at is captured at the original tap and survives every replay, so
    // this stable tuple prevents a retry from creating a second review/log or
    // regressing a card that has since advanced.
    final existing = await client
        .from('review_log')
        .select('id')
        .eq('card_id', e['card_id'])
        .eq('rating_at', e['last_review'])
        .eq('device', e['device'])
        .order('id', ascending: false)
        .limit(1);
    if (existing.isNotEmpty) {
      return (existing.first['id'] as num?)?.toInt();
    }

    await _updateCard(e);

    final inserted = await client
        .from('review_log')
        .insert(_reviewLogPayload(e))
        .select('id')
        .single();
    return (inserted['id'] as num?)?.toInt();
  }

  Future<void> _updateCard(Map<String, dynamic> e) async {
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
  }

  Map<String, dynamic> _reviewLogPayload(
    Map<String, dynamic> e, {
    String? clientEventId,
  }) => {
    'card_id': e['card_id'],
    'guid': e['guid'],
    'rating': e['rating'],
    'rating_at': e['last_review'],
    'stability_after': e['stability'],
    'difficulty_after': e['difficulty'],
    'due_after': e['due'],
    'state_after': e['state'],
    'elapsed_ms': e['elapsed_ms'],
    'device': e['device'],
    'client_event_id': ?clientEventId,
  };

  /// Undo one already-synced review: write the pre-rating scheduling state
  /// back to the cards row (same columns [applyReview] touches, including the
  /// snapshotted cloud_seen) and delete the review_log row it produced.
  /// review_log is otherwise append-only — this single-row delete is the
  /// accepted exception (single user; keeps retention stats clean).
  Future<void> undoReview(Map<String, dynamic> e) async {
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
          'cloud_seen': e['cloud_seen'],
        })
        .eq('id', e['card_id']);

    final logId = e['review_log_id'];
    if (logId != null) {
      await client.from('review_log').delete().eq('id', logId);
    }
  }

  /// Insert one queued note flag into `note_flags`. Its durable client event
  /// id is protected by the same server uniqueness contract as reviews.
  /// user_id/status default server-side. Throws if the row can't be inserted
  /// (e.g. the table doesn't exist yet) — the caller keeps the flag queued.
  Future<void> applyFlag(Map<String, dynamic> e) async {
    final eventId = e['client_id']?.toString();
    final payload = <String, dynamic>{
      'card_id': e['card_id'],
      'guid': e['guid'],
      'reason': e['reason'],
      'flagged_at': e['flagged_at'],
      'device': e['device'],
      'client_event_id': ?eventId,
    };
    if (eventId == null) {
      await client.from('note_flags').insert(payload);
      return;
    }
    try {
      await client
          .from('note_flags')
          .upsert(
            payload,
            onConflict: 'card_id,client_event_id',
            ignoreDuplicates: true,
          );
    } on PostgrestException catch (error) {
      if (!_idempotencySchemaUnavailable(error)) rethrow;
      payload.remove('client_event_id');
      await client.from('note_flags').insert(payload);
    }
  }

  bool _idempotencySchemaUnavailable(PostgrestException error) =>
      error.code == '42703' ||
      error.code == '42P10' ||
      error.code == 'PGRST204';

  /// Enriched review-log rows (local timestamp, rating, post-review state and
  /// scheduled due) for the Stats screen's heatmap + retention.
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async {
    final since = DateTime.now()
        .toUtc()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows = await client
        .from('review_log')
        .select('rating_at,rating,state_after,due_after')
        .gte('rating_at', since)
        .order('rating_at', ascending: true);
    return [
      for (final r in rows)
        ReviewLogEntry(
          at: DateTime.parse(r['rating_at'] as String).toLocal(),
          rating: (r['rating'] as num).toInt(),
          stateAfter: (r['state_after'] as num?)?.toInt(),
          dueAfter: r['due_after'] == null
              ? null
              : DateTime.parse(r['due_after'] as String).toLocal(),
        ),
    ];
  }

  /// Upcoming due dates (local) for scheduled (non-new) cards — powers the due
  /// forecast. Suspended cards are dormant and generate no upcoming workload,
  /// so they're excluded here too. With ~1.2k cards a plain ranged select is
  /// well within limits.
  Future<List<DateTime>> fetchDueDates() async {
    final rows = await client
        .from('cards')
        .select('due')
        .eq('deleted', false)
        .eq('suspended', false)
        .neq('state', 0)
        .not('due', 'is', null)
        .limit(5000);
    return [
      for (final r in rows)
        if (r['due'] != null) DateTime.parse(r['due'] as String).toLocal(),
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

String recallDeviceLabel({
  required bool isWeb,
  required TargetPlatform targetPlatform,
}) {
  if (isWeb) return 'web';
  return switch (targetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    _ => 'desktop',
  };
}

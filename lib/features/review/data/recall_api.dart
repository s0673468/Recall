import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../settings/domain/recall_prefs.dart';
import '../domain/stats_models.dart';
import 'models.dart';
import 'review_replay.dart';

/// All Supabase reads/writes for Recall. RLS scopes every row to the signed-in
/// user, so no explicit user_id filter is needed.
///
/// Implements [ReviewReplayGateway] so the multi-device conflict policy in
/// `review_replay.dart` runs against Supabase here and against a modelled
/// server in tests — one algorithm, two transports.
class RecallApi implements ReviewReplayGateway {
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

  /// A bonus batch for "Keep going" after the daily queue is done: cards due
  /// within [horizon] (soonest first — which naturally recaptures learning
  /// cards that came due minutes ahead), topped up to [limit] with new cards
  /// beyond the day's batch. Returns empty when there is truly nothing more.
  Future<List<ReviewCard>> fetchAheadQueue({
    int? deckId,
    Duration horizon = const Duration(hours: 24),
    int limit = 20,
    NewOrder order = NewOrder.oldestFirst,
  }) async {
    final now = DateTime.now().toUtc();
    final horizonIso = now.add(horizon).toIso8601String();

    PostgrestFilterBuilder<List<Map<String, dynamic>>> aheadQ = client
        .from('cards')
        .select(_cardSelect)
        .eq('deleted', false)
        .eq('suspended', false)
        .neq('state', 0)
        .lte('due', horizonIso);
    if (deckId != null) {
      aheadQ = aheadQ.eq('notes.deck_id', deckId);
    }
    final aheadRows = await aheadQ
        .order('due', ascending: true)
        .limit(limit);
    final ahead = [
      for (final r in aheadRows)
        ReviewCard.fromRow(Map<String, dynamic>.from(r)),
    ];

    final newSlots = limit - ahead.length;
    if (newSlots <= 0) return ahead;

    PostgrestFilterBuilder<List<Map<String, dynamic>>> newQ = client
        .from('cards')
        .select(_cardSelect)
        .eq('deleted', false)
        .eq('suspended', false)
        .eq('state', 0);
    if (deckId != null) {
      newQ = newQ.eq('notes.deck_id', deckId);
    }
    final newAscending = order != NewOrder.newestFirst;
    final newRows = await newQ
        .order('id', ascending: newAscending)
        .limit(newSlots);
    var newCards = [
      for (final r in newRows) ReviewCard.fromRow(Map<String, dynamic>.from(r)),
    ];
    if (order == NewOrder.random) {
      newCards = seededShuffle(
        newCards,
        newOrderDaySeed(DateTime.now(), deckId),
      );
    }
    return [...ahead, ...newCards];
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
    // Whether this rating cost a lapse, as a *delta*. The absolute `lapses`
    // above is computed off this device's snapshot and is only a fallback for
    // a fresh card; the replay increments the server's counter by this flag so
    // a second device's lapse is never overwritten. See [reviewLapsed].
    'lapsed': o.lapses > card.lapses,
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

  /// Replay one review entry against Supabase: merge the card's FSRS state and
  /// append a log row. Returns the review_log id so a later undo can target
  /// exactly this row.
  ///
  /// Prefers the `apply_review` RPC, which does both writes in one transaction
  /// keyed on `client_event_id` and is therefore genuinely idempotent under the
  /// outbox's at-least-once delivery. Falls back to [_applyReviewClientSide]
  /// when the function isn't deployed.
  Future<int?> applyReview(Map<String, dynamic> e) async {
    final eventId = e['client_id']?.toString();
    if (eventId != null) {
      try {
        return await _applyReviewViaRpc(e, eventId);
      } on PostgrestException catch (error) {
        if (!_rpcUnavailable(error)) rethrow;
        debugPrint('Recall: apply_review RPC absent; using client-side replay');
      }
    }
    return _applyReviewClientSide(e);
  }

  /// One round trip, one transaction. The server anchors idempotency on the
  /// `(card_id, client_event_id)` unique index, so a replay cannot re-count a
  /// review no matter where a previous attempt died — the gap the client-side
  /// path can only narrow, never close (see README, "Replay is not fully
  /// idempotent").
  Future<int?> _applyReviewViaRpc(Map<String, dynamic> e, String eventId) async {
    final id = await client.rpc<Object?>(
      'apply_review',
      params: {
        'p_card_id': e['card_id'],
        'p_guid': e['guid'],
        'p_rating': e['rating'],
        'p_rating_at': e['last_review'],
        'p_stability': e['stability'],
        'p_difficulty': e['difficulty'],
        'p_due': e['due'],
        'p_state': e['state'],
        'p_lapsed': reviewLapsed(e),
        'p_elapsed_ms': e['elapsed_ms'],
        'p_device': e['device'],
        'p_client_event_id': eventId,
      },
    );
    return (id as num?)?.toInt();
  }

  /// PostgREST reports an undeployed function as 404/PGRST202. Anything else is
  /// a real failure and must not be swallowed into the fallback, or a broken
  /// RPC would silently downgrade every device to the weaker path forever.
  bool _rpcUnavailable(PostgrestException error) =>
      error.code == 'PGRST202' || error.code == '404' || error.code == '42883';

  /// Pre-RPC replay: probe the ledger, merge the card, append the log. Three
  /// separate guards, in order:
  ///  1. **Duplicate suppression** — the `client_event_id` ledger short-circuits
  ///     a replay of the *same* review before anything is written.
  ///  2. **Conflict merge** — [applyMergedReview] reconciles this review with
  ///     whatever another device has already written (see `review_replay.dart`).
  ///  3. **Log append** — never re-runs step 2, so a missing ledger column can
  ///     cost us the dedup key without also double-counting the review.
  Future<int?> _applyReviewClientSide(Map<String, dynamic> e) async {
    final eventId = e['client_id']?.toString();
    // Null once we know the ledger column isn't deployed — the whole call then
    // falls back to the legacy (rating_at, device) dedup tuple.
    var ledgerEventId = eventId;
    if (eventId != null) {
      try {
        final existing = await _findLogByEventId(e['card_id'], eventId);
        if (existing != null) return existing;
      } on PostgrestException catch (error) {
        if (!_idempotencySchemaUnavailable(error)) rethrow;
        // Rolling-deploy compatibility only. Once the checked-in migration is
        // applied, every native review takes the server-enforced path above.
        debugPrint(
          'Recall: idempotency schema not deployed; using legacy replay',
        );
        ledgerEventId = null;
      }
    }
    if (ledgerEventId == null) {
      final existing = await _findLogLegacy(e);
      if (existing != null) return existing;
    }

    await applyMergedReview(this, e);
    return _insertReviewLog(e, ledgerEventId);
  }

  Future<int?> _findLogByEventId(Object cardId, String eventId) async {
    final existing = await client
        .from('review_log')
        .select('id')
        .eq('card_id', cardId)
        .eq('client_event_id', eventId)
        .limit(1);
    return existing.isEmpty ? null : (existing.first['id'] as num?)?.toInt();
  }

  /// The local outbox is at-least-once: a network response or the on-device
  /// acknowledgement write can fail after Supabase committed the insert.
  /// rating_at is captured at the original tap and survives every replay, so
  /// this stable tuple prevents a retry from creating a second review/log or
  /// regressing a card that has since advanced.
  Future<int?> _findLogLegacy(Map<String, dynamic> e) async {
    final existing = await client
        .from('review_log')
        .select('id')
        .eq('card_id', e['card_id'])
        .eq('rating_at', e['last_review'])
        .eq('device', e['device'])
        .order('id', ascending: false)
        .limit(1);
    return existing.isEmpty ? null : (existing.first['id'] as num?)?.toInt();
  }

  /// Append the log row for an already-merged review. If the ledger column
  /// turns out to be missing at this point the card is already updated, so it
  /// logs without the key rather than replaying the merge and double-counting.
  Future<int?> _insertReviewLog(
    Map<String, dynamic> e,
    String? clientEventId,
  ) async {
    if (clientEventId != null) {
      try {
        final inserted = await client
            .from('review_log')
            .upsert(
              _reviewLogPayload(e, clientEventId: clientEventId),
              onConflict: 'card_id,client_event_id',
            )
            .select('id')
            .single();
        return (inserted['id'] as num?)?.toInt();
      } on PostgrestException catch (error) {
        if (!_idempotencySchemaUnavailable(error)) rethrow;
        debugPrint('Recall: review logged without its durable event id');
      }
    }
    final inserted = await client
        .from('review_log')
        .insert(_reviewLogPayload(e))
        .select('id')
        .single();
    return (inserted['id'] as num?)?.toInt();
  }

  @override
  Future<CardSyncState?> readCardState(int cardId) async {
    final row = await client
        .from('cards')
        .select('reps,lapses,last_review')
        .eq('id', cardId)
        .maybeSingle();
    return row == null
        ? null
        : CardSyncState.fromRow(Map<String, dynamic>.from(row));
  }

  @override
  Future<int> updateCardWhereReps(
    int cardId, {
    required int? expectedReps,
    required Map<String, dynamic> values,
  }) async {
    final update = client.from('cards').update(values).eq('id', cardId);
    // `reps` doubles as the row version: an applied review always bumps it by
    // one, so requiring the value we read makes the write compare-and-swap.
    // NULL needs `IS NULL` — SQL equality never matches it.
    final guarded = expectedReps == null
        ? update.isFilter('reps', null)
        : update.eq('reps', expectedReps);
    final updated = await guarded.select('id');
    return updated.length;
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
        .select('guid,rating_at,rating,state_after,due_after')
        .gte('rating_at', since)
        .order('rating_at', ascending: true);
    return [
      for (final r in rows)
        ReviewLogEntry(
          guid: r['guid'] as String?,
          at: DateTime.parse(r['rating_at'] as String).toLocal(),
          rating: (r['rating'] as num).toInt(),
          stateAfter: (r['state_after'] as num?)?.toInt(),
          dueAfter: r['due_after'] == null
              ? null
              : DateTime.parse(r['due_after'] as String).toLocal(),
        ),
    ];
  }

  /// note guid -> raw space-delimited `tags` string, for live notes that carry
  /// at least one `node::` tag. Powers the Concepts (node-retention) section:
  /// the service parses `node::<id>` tokens out of each tag string. Only tagged
  /// notes are fetched, so the payload stays small.
  Future<Map<String, String>> fetchNoteTags() async {
    final rows = await client
        .from('notes')
        .select('guid,tags')
        .eq('deleted', false)
        .like('tags', '%node::%');
    return {
      for (final r in rows)
        if (r['guid'] != null) (r['guid'] as String): (r['tags'] as String?) ?? '',
    };
  }

  /// The METIS concept nodes (id -> title/module) mirrored into the cloud, used
  /// to label the Concepts section. Tolerates an empty table — the section then
  /// falls back to raw node ids (or hides when there is no node data at all).
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async {
    final rows = await client
        .from('concept_nodes')
        .select('node_id,title,module');
    return [
      for (final r in rows)
        ConceptNodeInfo(
          nodeId: r['node_id'] as String,
          title: (r['title'] as String?) ?? r['node_id'] as String,
          module: (r['module'] as String?) ?? '',
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

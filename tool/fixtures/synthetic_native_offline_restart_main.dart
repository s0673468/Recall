import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'synthetic_recall_flow.dart';

const _source = String.fromEnvironment('RECALL_BENCH_SOURCE_COMMIT');
const _enabled = bool.fromEnvironment('RECALL_SYNTHETIC_NATIVE_OFFLINE');
const _schema = 'recall-native-offline-restart/v2';
const _package = 'com.german.recall.syntheticbenchmark';
const _marker = 'recall.synthetic.native_offline.phase.v1';
String _phase = 'fixture_guard';
String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
void _require(bool ok) {
  if (!ok) throw StateError('synthetic_contract_refused');
}

void _emit(Map<String, dynamic> value) =>
    print('RECALL_NATIVE_OFFLINE_JSON ${jsonEncode(value)}');

// This guard runs before SharedPreferences.getInstance. Driver APK inspection
// also checks the application ID; the entry itself refuses the normal Recall
// process even if somebody builds it with the synthetic Dart defines.
bool syntheticNativeProcessIdentity(List<int> bytes) {
  final end = bytes.indexOf(0);
  if (end <= 0 || bytes.length > 128) return false;
  try {
    return utf8.decode(bytes.sublist(0, end)) == _package;
  } on FormatException {
    return false;
  }
}

Future<void> _requireSyntheticNativeProcess() async {
  final ownProcess = await File('/proc/self/cmdline').open();
  try {
    _require(syntheticNativeProcessIdentity(await ownProcess.read(128)));
  } finally {
    await ownProcess.close();
  }
}

String _canonicalPayload(Map<String, dynamic> body) {
  final keys = body.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: body[key]});
}

// No real HTTP sockets: every request reaches this .invalid-only mock.
// Public only so parent CI can test the generated HTTP fixture without startup.
class SyntheticNativeOfflineHttp extends SyntheticRecallHttp {
  SyntheticNativeOfflineHttp(super.cards, this.ownerHash);
  final String ownerHash;
  bool offlineReads = false;
  bool onlineWrites = false;
  bool loseNextAck = false;
  int offlineAttempts = 0;
  int onlineAttempts = 0;
  final Map<String, int> accepted = {};
  final Map<String, String> _acceptedPayloads = {};
  final Set<int> acceptedCards = {};
  final List<String> receivedHashes = [];
  String eventHash(String id) =>
      _hash('recall-native-event/v1\u0000$ownerHash\u0000$id');
  @override
  Future<http.Response> respond(http.Request request) async {
    _require(
      request.url.scheme == 'https' &&
          request.url.host == 'recall-bench.invalid' &&
          request.url.port == 443 &&
          request.url.userInfo.isEmpty,
    );
    if (request.url.path.endsWith('/rpc/apply_review')) {
      _require(request.method == 'POST');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      _require(
        body['p_client_event_id'] is String &&
            (body['p_client_event_id'] as String).isNotEmpty &&
            body['p_card_id'] == 1 &&
            body['p_guid'] == 'synthetic-card-1',
      );
      counts['apply_review'] = counts['apply_review']! + 1;
      if (!onlineWrites) {
        offlineAttempts++;
        return http.Response(
          '{"message":"synthetic offline"}',
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      onlineAttempts++;
      final id = body['p_client_event_id'] as String;
      final payloadHash = _hash(_canonicalPayload(body));
      final previousPayload = _acceptedPayloads[id];
      _require(previousPayload == null || previousPayload == payloadHash);
      _acceptedPayloads[id] = payloadHash;
      receivedHashes.add(eventHash(id));
      final result = accepted.putIfAbsent(id, () => 9001);
      acceptedCards.add(1);
      if (loseNextAck) {
        loseNextAck = false;
        return http.Response(
          '{"message":"synthetic lost acknowledgement"}',
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '$result',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (offlineReads) throw http.ClientException('synthetic offline');
    final response = await super.respond(request);
    if (request.url.path.endsWith('/cards') &&
        request.url.queryParameters['state'] == 'neq.0') {
      final rows = jsonDecode(response.body) as List;
      return http.Response(
        jsonEncode(
          rows
              .where((row) => !acceptedCards.contains((row as Map)['id']))
              .toList(),
        ),
        response.statusCode,
        headers: response.headers,
      );
    }
    if (request.url.path.endsWith('/rpc/deck_counts')) {
      return http.Response(
        jsonEncode([
          {'deck_id': 1, 'due': cards.length - acceptedCards.length, 'new': 0},
        ]),
        response.statusCode,
        headers: response.headers,
      );
    }
    return response;
  }
}

class _NativeFlow {
  _NativeFlow(
    this.transport,
    this.client,
    this.api,
    this.store,
    this.controller,
  );
  final SyntheticNativeOfflineHttp transport;
  final SupabaseClient client;
  final SyntheticAuthRecallApi api;
  final TimedLocalReviewStore store;
  final ReviewController controller;
  bool disposed = false;
  static Future<_NativeFlow> create() async {
    final cards = List<ReviewCard>.generate(20, (i) => syntheticCard(i + 1));
    final transport = SyntheticNativeOfflineHttp(
      cards,
      _hash('synthetic-benchmark-owner'),
    );
    final client = SupabaseClient(
      'https://recall-bench.invalid',
      'synthetic-public-key',
      httpClient: MockClient(transport.respond),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final api = SyntheticAuthRecallApi(client);
    final store = TimedLocalReviewStore();
    await store.activateOwner(api.currentUser!.id);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      haptics: const ReviewHaptics(),
    );
    return _NativeFlow(transport, client, api, store, controller);
  }

  Future<void> settle() async {
    await store.outbox();
    await store.flagOutbox();
  }

  Future<void> close() async {
    if (!disposed) {
      disposed = true;
      controller.dispose();
    }
    await settle();
    await Future<void>.sync(client.dispose);
  }

  String eventHash(Map<String, dynamic> event) =>
      transport.eventHash(event['client_id'] as String);
  Future<String> snapshotHash() async {
    final snapshot = await store.loadSnapshot();
    _require(snapshot != null);
    final restored = snapshot!;
    final decks = restored.decks.map((d) => d.deckId).toList()..sort();
    return _hash(
      jsonEncode({
        'decks': decks,
        'queue': [
          for (final card in restored.queue)
            {'id': card.id, 'guid_sha256': _hash(card.guid)},
        ],
      }),
    );
  }

  Map<String, dynamic> common(String phase, String event, String snapshot) => {
    'schema': _schema,
    'source_commit': _source,
    'phase': phase,
    'package': _package,
    'pid': pid,
    'build_mode': 'debug',
    'environment': 'github-hosted-isolated-android-emulator',
    'native_preferences': true,
    'owner_sha256': _hash(api.currentUser!.id),
    'event_sha256': event,
    'snapshot_identity_sha256': snapshot,
    'os_airplane_state_observed_by_app': false,
    'physical_radio_state_covered': false,
    'real_provider_contacted': false,
    'auth_identity_injected': true,
  };
}

Future<Map<String, dynamic>> _run(SharedPreferences prefs) async {
  final rawMarker = prefs.getString(_marker);
  final flow = await _NativeFlow.create();
  try {
    if (rawMarker == null) {
      _phase = 'offline_recording';
      _require(
        (await flow.store.outbox()).isEmpty &&
            await flow.store.loadSnapshot() == null,
      );
      await flow.controller.load();
      _require(
        flow.controller.state.error == null &&
            !flow.controller.state.offline &&
            flow.controller.state.current?.id == 1,
      );
      flow.transport.offlineReads = true;
      await flow.controller.refresh();
      _require(
        flow.controller.state.offline && flow.controller.state.current?.id == 1,
      );
      flow.controller.flip();
      await flow.controller.rate(Rating.good);
      await flow.controller.rate(
        Rating.good,
      ); // Unrevealed next card must not duplicate.
      await flow.controller.syncPending();
      await flow.settle();
      final pending = await flow.store.outbox();
      _require(
        pending.length == 1 &&
            pending.single['card_id'] == 1 &&
            flow.controller.state.current?.id == 2 &&
            flow.controller.state.reviewedThisSession == 1 &&
            flow.transport.offlineAttempts > 0 &&
            flow.transport.accepted.isEmpty,
      );
      final event = flow.eventHash(pending.single);
      // Snapshot write joins the controller's queued store operations.
      final snapshot = await flow.snapshotHash();
      final receipt = {
        ...flow.common('offline_recorded', event, snapshot),
        'pending_count': pending.length,
        'current_card_id': 2,
        'reviewed_this_session': 1,
        'native_platform_ack_observed': true,
        'native_enqueue_ack_us': flow.store.lastEnqueueAckUs,
        'offline_rpc_attempts': flow.transport.offlineAttempts,
        'fake_unique_accept_count': 0,
        'phase_marker_native_ack_observed': true,
        'power_loss_durability_tested': false,
      };
      _require(
        await prefs.setString(
          _marker,
          jsonEncode({
            'phase': 'awaiting_restart',
            'source_commit': _source,
            'owner_sha256': receipt['owner_sha256'],
            'event_sha256': event,
            'snapshot_identity_sha256': snapshot,
          }),
        ),
      );
      return receipt;
    }
    _phase = 'native_restore';
    final marker = jsonDecode(rawMarker) as Map<String, dynamic>;
    _require(
      marker['phase'] == 'awaiting_restart' &&
          marker['source_commit'] == _source,
    );
    final pending = await flow.store.outbox();
    _require(pending.length == 1 && pending.single['card_id'] == 1);
    final event = flow.eventHash(pending.single);
    final snapshot = await flow.snapshotHash();
    _require(
      event == marker['event_sha256'] &&
          snapshot == marker['snapshot_identity_sha256'] &&
          _hash(flow.api.currentUser!.id) == marker['owner_sha256'],
    );
    await flow.store.activateOwner('synthetic-other-owner');
    final otherPending = await flow.store.outbox();
    final otherSnapshot = await flow.store.loadSnapshot();
    _require(otherPending.isEmpty && otherSnapshot == null);
    await flow.store.activateOwner(flow.api.currentUser!.id);
    flow.transport.offlineReads = true;
    await flow.controller.load();
    _require(
      flow.controller.state.offline &&
          flow.controller.state.current?.id == 2 &&
          !flow.controller.canUndo &&
          flow.controller.state.queue.every((card) => card.id != 1),
    );
    // Join all offline work before changing the mock transport mode.
    await flow.controller.syncPending();
    final restartedPending = await flow.store.outbox();
    final restartedCurrent = flow.controller.state.current?.id;
    final restartedUndo = flow.controller.canUndo;
    _require(
      restartedPending.length == 1 &&
          flow.eventHash(restartedPending.single) == event &&
          restartedCurrent == 2 &&
          !restartedUndo,
    );
    _phase = 'fake_sync';
    flow.transport.offlineReads = false;
    flow.transport.onlineWrites = true;
    flow.transport.loseNextAck = true;
    await flow.controller.syncPending();
    final afterLost = await flow.store.outbox();
    _require(
      afterLost.length == 1 && flow.eventHash(afterLost.single) == event,
    );
    await flow.controller.syncPending();
    final afterAck = await flow.store.outbox();
    _require(
      afterAck.isEmpty &&
          flow.transport.onlineAttempts == 2 &&
          flow.transport.accepted.length == 1 &&
          flow.transport.receivedHashes.length == 2 &&
          flow.transport.receivedHashes.every((value) => value == event),
    );
    await flow.controller.refresh();
    _require(
      flow.controller.state.current?.id == 2 &&
          !flow.controller.state.offline &&
          flow.controller.state.queue.every((card) => card.id != 1),
    );
    final receipt = {
      ...flow.common('restart_synced', event, snapshot),
      'phase_marker_restored': true,
      'event_restored_before_load': true,
      'snapshot_restored_before_load': true,
      'other_owner_sha256': _hash('synthetic-other-owner'),
      'other_owner_pending_count': otherPending.length,
      'other_owner_snapshot_present': false,
      'pending_after_restart': restartedPending.length,
      'current_after_restart': restartedCurrent,
      'rated_card_requeued': false,
      'undo_available': restartedUndo,
      'pending_after_lost_ack': afterLost.length,
      'event_sha256_after_lost_ack': flow.eventHash(afterLost.single),
      'fake_online_rpc_attempts': flow.transport.onlineAttempts,
      'fake_unique_accept_count': flow.transport.accepted.length,
      'fake_received_event_sha256': flow.transport.receivedHashes,
      'pending_after_ack': afterAck.length,
      'native_remove_ack_observed': true,
      'current_after_online_refresh': 2,
    };
    _require(
      await prefs.setString(
        _marker,
        jsonEncode({'phase': 'completed', 'source_commit': _source}),
      ),
    );
    return receipt;
  } finally {
    await flow.close();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_enabled ||
      !kDebugMode ||
      !Platform.isAndroid ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(_source)) {
    _emit({
      'schema': _schema,
      'phase': 'failed',
      'source_commit': _source,
      'pid': pid,
      'failure_code': 'fixture_build_required',
      'failed_phase': 'fixture_guard',
    });
    return;
  }
  try {
    await _requireSyntheticNativeProcess();
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Synthetic native restart acceptance')),
        ),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final receipt = await _run(prefs).timeout(const Duration(seconds: 40));
    _emit(receipt);
  } catch (_) {
    _emit({
      'schema': _schema,
      'phase': 'failed',
      'source_commit': _source,
      'pid': pid,
      'failure_code': 'synthetic_phase_failed',
      'failed_phase': _phase,
    });
  }
}

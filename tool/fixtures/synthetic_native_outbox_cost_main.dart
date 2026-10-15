import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'synthetic_native_offline_restart_main.dart' as framing;
import 'synthetic_recall_flow.dart';

const outboxCostSchema = 'recall-native-outbox-cost/v1';
const _sourceCommit = String.fromEnvironment('RECALL_SOURCE_COMMIT');
const _baseCommit = String.fromEnvironment('RECALL_BASE_COMMIT');
const _variant = String.fromEnvironment('RECALL_VARIANT');
const _controllerSha = String.fromEnvironment('RECALL_CONTROLLER_SHA256');
const _patchSha = String.fromEnvironment('RECALL_PATCH_SHA256');
const _fixtureSha = String.fromEnvironment('RECALL_FIXTURE_SHA256');
const _enabled = bool.fromEnvironment('RECALL_SYNTHETIC_NATIVE_OUTBOX_COST');
const _package = 'com.german.recall.syntheticbenchmark';
const _storeBlob = '3f8ad48c4907a9bf4f7a28b67223229d491e076a';
const _baselineControllerSha =
    'b7dd000dbf64598addbb880b0eb49f9866b65003f8fffb6ea766fc32cd474d88';
const _checkpointControllerSha =
    '5df361de71751f2733d2d75ecad863dcfac1cbe979a571a0e27a28ddf4cd51db';
const _checkpointPatchSha =
    'e052e44873fabad289a80c6185dcaf4b46afe491f8529ca172b5b5b589a91578';

void _require(bool condition) {
  if (!condition) throw StateError('synthetic_outbox_contract_refused');
}

/// Delegates every operation to the captured platform implementation. Only an
/// acknowledged String write to one owner-scoped review outbox is measured.
class NativeOutboxWriteProbe extends SharedPreferencesStorePlatform {
  NativeOutboxWriteProbe(this.delegate);

  final SharedPreferencesStorePlatform delegate;
  String? targetKey;
  int acknowledgedWrites = 0;
  int acknowledgedChars = 0;
  int acknowledgedUtf8Bytes = 0;
  int ackTotalUs = 0;
  int ackMaxUs = 0;

  void resetFor(String key) {
    targetKey = key;
    acknowledgedWrites = 0;
    acknowledgedChars = 0;
    acknowledgedUtf8Bytes = 0;
    ackTotalUs = 0;
    ackMaxUs = 0;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key != targetKey) return delegate.setValue(valueType, key, value);
    _require(valueType == 'String' && value is String);
    final stringValue = value as String;
    final watch = Stopwatch()..start();
    final accepted = await delegate.setValue(valueType, key, value);
    watch.stop();
    if (accepted) {
      acknowledgedWrites++;
      acknowledgedChars += stringValue.length;
      acknowledgedUtf8Bytes += utf8.encode(stringValue).length;
      ackTotalUs += watch.elapsedMicroseconds;
      if (watch.elapsedMicroseconds > ackMaxUs) {
        ackMaxUs = watch.elapsedMicroseconds;
      }
    }
    return accepted;
  }

  @override
  Future<bool> remove(String key) => delegate.remove(key);
  @override
  Future<bool> clear() => delegate.clear();
  @override
  Future<bool> clearWithPrefix(String prefix) =>
      // ignore: deprecated_member_use
      delegate.clearWithPrefix(prefix);
  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      delegate.clearWithParameters(parameters);
  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();
  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      // ignore: deprecated_member_use
      delegate.getAllWithPrefix(prefix);
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => delegate.getAllWithParameters(parameters);
}

/// Test-only subclass: the inherited persistence, lock and owner behavior are
/// the production Store. Durations include the native ACK interval and overlap.
class TimedOutboxCostStore extends LocalReviewStore {
  int markCalls = 0;
  int removeCalls = 0;
  int markTotalUs = 0;
  int removeTotalUs = 0;
  final Set<String> markedBeforeTransport = {};

  @override
  Future<bool> markReviewAttempted(
    Object clientId, {
    String? ownerScope,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final marked = await super.markReviewAttempted(
        clientId,
        ownerScope: ownerScope,
      );
      if (marked) markedBeforeTransport.add(clientId.toString());
      return marked;
    } finally {
      watch.stop();
      markCalls++;
      markTotalUs += watch.elapsedMicroseconds;
    }
  }

  @override
  Future<int> removeFirst(int count, {String? ownerScope}) async {
    final watch = Stopwatch()..start();
    try {
      return await super.removeFirst(count, ownerScope: ownerScope);
    } finally {
      watch.stop();
      removeCalls++;
      removeTotalUs += watch.elapsedMicroseconds;
    }
  }
}

class TrackedSyntheticOutboxHttp extends SyntheticRecallHttp {
  TrackedSyntheticOutboxHttp(this.store) : super(const []);

  final TimedOutboxCostStore store;
  final Set<String> requestedIds = {};
  final Set<String> acceptedIds = {};

  @override
  Future<http.Response> respond(http.Request request) async {
    _require(request.url.scheme == 'https');
    _require(request.url.host == 'recall-bench.invalid');
    _require(request.url.port == 443 && request.url.userInfo.isEmpty);
    if (!request.url.path.endsWith('/rpc/apply_review')) {
      throw StateError('synthetic_outbox_unexpected_request');
    }
    _require(request.method == 'POST');
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final id = payload['p_client_event_id'];
    final cardId = payload['p_card_id'];
    _require(id is String && id.startsWith('synthetic-seed-'));
    final index = int.tryParse(id.substring('synthetic-seed-'.length));
    _require(index != null && cardId == 100000 + index);
    _require(store.markedBeforeTransport.contains(id));
    _require(requestedIds.add(id));
    final response = await super.respond(request);
    if (response.statusCode == 200) acceptedIds.add(id);
    return response;
  }
}

class OutboxCostSample {
  const OutboxCostSample({
    required this.pendingSeeded,
    required this.syncPendingUs,
    required this.store,
    required this.probe,
    required this.transport,
    required this.apiApplyUs,
  });

  final int pendingSeeded;
  final int syncPendingUs;
  final TimedOutboxCostStore store;
  final NativeOutboxWriteProbe probe;
  final TrackedSyntheticOutboxHttp transport;
  final int apiApplyUs;

  Map<String, dynamic> metrics() => {
    'timing_us': {
      'sync_pending': syncPendingUs,
      'mark_total': store.markTotalUs,
      'remove_total': store.removeTotalUs,
      'native_ack_total': probe.ackTotalUs,
      'native_ack_max': probe.ackMaxUs,
      'api_apply_total': apiApplyUs,
    },
    'counts': {
      'mark_calls': store.markCalls,
      'remove_calls': store.removeCalls,
      'native_ack_writes': probe.acknowledgedWrites,
      'native_ack_chars': probe.acknowledgedChars,
      'native_ack_utf8_bytes': probe.acknowledgedUtf8Bytes,
      'apply_review_requests': transport.counts['apply_review'],
      'accepted_unique': transport.acceptedIds.length,
      'pending_after': 0,
    },
  };
}

/// One drain; seeding and owner activation finish before probes are reset.
/// Tests can inject an in-memory delegate; the Android entrypoint rejects it.
Future<OutboxCostSample> measureSyntheticOutboxCost({
  required int pendingCount,
  required SharedPreferencesStorePlatform delegate,
}) async {
  _require(pendingCount > 0);
  final previous = SharedPreferencesStorePlatform.instance;
  final probe = NativeOutboxWriteProbe(delegate);
  SharedPreferencesStorePlatform.instance = probe;
  final store = TimedOutboxCostStore();
  final transport = TrackedSyntheticOutboxHttp(store)..deliverReviews = true;
  final client = SupabaseClient(
    'https://recall-bench.invalid',
    'synthetic-public-key',
    httpClient: MockClient(transport.respond),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final api = SyntheticAuthRecallApi(client);
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
  );
  try {
    await store.activateOwner(api.currentUser!.id);
    final scope = store.activeOwnerScope;
    _require(scope != null && store.isActiveOwner(api.currentUser!.id));
    final key = 'recall_outbox_v1:owner:$scope';
    final platformKey = 'flutter.$key';
    final prefs = await SharedPreferences.getInstance();
    final entries = List<Map<String, dynamic>>.generate(
      pendingCount,
      syntheticPendingReview,
      growable: false,
    );
    _require(await prefs.setString(key, jsonEncode(entries)));
    _require((await store.outbox(ownerScope: scope)).length == pendingCount);
    probe.resetFor(platformKey);

    final watch = Stopwatch()..start();
    await controller.syncPending();
    watch.stop();
    final syncPendingUs = watch.elapsedMicroseconds;

    // Reload makes the final empty state an actual platform read, not merely
    // the legacy SharedPreferences Dart cache's optimistic write-through.
    await prefs.reload();
    final nativeList = jsonDecode(prefs.getString(key) ?? 'null');
    _require(nativeList is List && nativeList.isEmpty);
    _require((await store.outbox(ownerScope: scope)).isEmpty);
    _require(store.activeOwnerScope == scope);
    _require(store.isActiveOwner(api.currentUser!.id));
    _require(store.markCalls == pendingCount);
    _require(store.markedBeforeTransport.length == pendingCount);
    _require(transport.requestedIds.length == pendingCount);
    _require(transport.counts['apply_review'] == pendingCount);
    _require(transport.acceptedIds.length == pendingCount);
    _require(transport.totalRequests == pendingCount);
    _require(store.removeCalls >= 1);
    _require(probe.acknowledgedWrites >= pendingCount + 1);
    return OutboxCostSample(
      pendingSeeded: pendingCount,
      syncPendingUs: syncPendingUs,
      store: store,
      probe: probe,
      transport: transport,
      apiApplyUs: api.applyReviewUs,
    );
  } finally {
    controller.dispose();
    try {
      await store.outbox();
    } finally {
      client.dispose();
      SharedPreferencesStorePlatform.instance = previous;
    }
  }
}

void requireExpectedOutboxCostCounts(OutboxCostSample sample, String variant) {
  final count = sample.pendingSeeded;
  _require(count == 128 || count == 512);
  final expectedRemoves = variant == 'baseline' ? 1 : count ~/ 32 + 1;
  final expectedWrites = variant == 'baseline'
      ? count + 1
      : count + count ~/ 32;
  _require(sample.store.markCalls == count);
  _require(sample.store.removeCalls == expectedRemoves);
  _require(sample.probe.acknowledgedWrites == expectedWrites);
}

int syntheticOutboxCountFromRoute(String route) => switch (route) {
  '/recall-outbox-cost/128' => 128,
  '/recall-outbox-cost/512' => 512,
  _ => throw StateError('synthetic_route_refused'),
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var failureCode = 'guard_refused';
  try {
    _require(_enabled && kDebugMode && Platform.isAndroid);
    _require(RegExp(r'^[0-9a-f]{40}$').hasMatch(_sourceCommit));
    _require(_baseCommit == 'b47ffde0fea3d60e9841b889b4f37aedfcb9bff9');
    _require(RegExp(r'^[0-9a-f]{64}$').hasMatch(_fixtureSha));
    _require(
      (_variant == 'baseline' &&
              _controllerSha == _baselineControllerSha &&
              _patchSha == 'none') ||
          (_variant == 'checkpoint' &&
              _controllerSha == _checkpointControllerSha &&
              _patchSha == _checkpointPatchSha),
    );
    final ownProcess = await File('/proc/self/cmdline').open();
    try {
      _require(
        framing.syntheticNativeProcessIdentity(await ownProcess.read(128)),
      );
    } finally {
      await ownProcess.close();
    }
    final pendingCount = syntheticOutboxCountFromRoute(
      ui.PlatformDispatcher.instance.defaultRouteName,
    );
    final delegate = SharedPreferencesStorePlatform.instance;
    _require(delegate is! InMemorySharedPreferencesStore);
    failureCode = 'measurement_refused';
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Synthetic outbox cost'))),
      ),
    );
    final sample = await measureSyntheticOutboxCost(
      pendingCount: pendingCount,
      delegate: delegate,
    );
    requireExpectedOutboxCostCounts(sample, _variant);
    final receipt = <String, dynamic>{
      'schema': outboxCostSchema,
      'phase': 'done',
      'source_commit': _sourceCommit,
      'baseline_source_commit': _baseCommit,
      'variant': _variant,
      'controller_sha256': _controllerSha,
      'store_git_blob': _storeBlob,
      'fixture_sha256': _fixtureSha,
      'patch_sha256': _patchSha,
      'package': _package,
      'pid': pid,
      'pending_seeded': sample.pendingSeeded,
      'build_mode': 'debug',
      'environment': 'isolated_android_fixture',
      'native_preferences': true,
      'fake_http_only': true,
      'power_loss_tested': false,
      'physical_device_tested': false,
      'real_provider_contacted': false,
      ...sample.metrics(),
    };
    for (final line in framing.syntheticNativeReceiptFrames(receipt)) {
      // ignore: avoid_print
      print(line);
    }
  } catch (_) {
    final failed = <String, dynamic>{
      'schema': outboxCostSchema,
      'phase': 'failed',
      'source_commit': _sourceCommit,
      'variant': _variant,
      'pid': pid,
      'failure_code': failureCode,
    };
    for (final line in framing.syntheticNativeReceiptFrames(failed)) {
      // ignore: avoid_print
      print(line);
    }
  }
}

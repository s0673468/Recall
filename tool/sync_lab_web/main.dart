// Synthetic browser-only adapter. The host supplies scratch SQL transport.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/core/background/browser_foreground_sync_coordinator.dart';
import 'package:health_anki_flutter/core/background/browser_sync_platform.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

@JS('recallSyncLabTransport')
external JSPromise<JSString> _transport(JSString request);

@JS('recallSyncLabCommand')
external set _command(JSFunction value);

class _BrowserDriver {
  static const sourceSha = String.fromEnvironment('SYNC_LAB_SOURCE_SHA');
  final store = LocalReviewStore();
  final trace = <Map<String, dynamic>>[];
  late final SupabaseClient client;
  late final RecallApi api;
  late final ReviewController controller;
  late final BrowserForegroundSyncCoordinator foreground;
  String? deviceId;
  int requestSequence = 0;
  int foregroundPasses = 0;
  final operationWitnesses = <Map<String, dynamic>>[];

  _BrowserDriver() {
    client = SupabaseClient(
      'https://recall-sync-lab.invalid',
      'synthetic-not-a-credential',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final frame = <String, dynamic>{
          'kind': 'transport',
          'requestId': ++requestSequence,
          'commandId': Zone.current[#syncLabCommandId],
          'deviceId': deviceId,
          'userId': client.auth.currentUser?.id,
          'method': request.method,
          'path': request.url.path,
          'url': request.url.toString(),
          'headers': request.headers,
          'query': request.url.queryParametersAll,
          'body': request.body,
          'surface': 'FlutterWeb.ReviewController.RecallApi.http',
        };
        trace.add(frame);
        final raw = await _transport(jsonEncode(frame).toJS).toDart;
        final response = jsonDecode(raw.toDart) as Map<String, dynamic>;
        if (response['ok'] != true) {
          throw http.ClientException('synthetic transport failure');
        }
        final status = response['status'];
        final body = response['body'];
        if (status is! int || body is! String) {
          throw const FormatException('Invalid scratch transport response');
        }
        trace.add({
          'surface': 'FlutterWeb.RecallApi.http.response',
          'requestId': frame['requestId'],
          'status': status,
        });
        return http.Response(
          body,
          status,
          request: request,
          headers: {
            'content-type': 'application/json',
            ...Map<String, String>.from(response['headers'] as Map? ?? {}),
          },
        );
      }),
    );
    api = RecallApi(client);
    controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      beforeSessionLoad: () async {
        final owner = api.currentUser?.id;
        if (owner != null) await store.activateOwner(owner);
      },
      afterSignOut: store.releaseOwner,
    );
    foreground = BrowserForegroundSyncCoordinator(
      platform: createBrowserSyncPlatform(),
      hasSession: () => api.currentUser != null,
      syncPending: () async {
        foregroundPasses++;
        await controller.syncPending();
      },
      refreshIfIdle: controller.refreshIfIdle,
      // Generated schedules explicitly wake the production coordinator.
      interval: const Duration(days: 1),
    );
  }

  Future<void> switchAccount(String? owner) async {
    if (owner == null) {
      await client.auth.signOut(scope: SignOutScope.local);
      await store.releaseOwner();
      return;
    }
    // This is a synthetic recovered session, never a real credential. GoTrue
    // emits its real account-change stream; the controller handles that stream.
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400;
    final token =
        '${encode({'alg': 'none', 'typ': 'JWT'})}.'
        '${encode({'sub': owner, 'exp': expiry, 'role': 'authenticated'})}.';
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': token,
        'refresh_token': 'synthetic-refresh-never-used',
        'token_type': 'bearer',
        'expires_in': 86400,
        'expires_at': expiry,
        'user': {
          'id': owner,
          'aud': 'authenticated',
          'role': 'authenticated',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }),
    );
    await store.activateOwner(owner);
  }

  Future<Map<String, dynamic>> status() async => {
    'surface': 'FlutterWeb.ReviewController',
    'sourceSha': sourceSha,
    'storage': 'SharedPreferences.browser',
    'deviceId': deviceId,
    'userId': api.currentUser?.id,
    'ownerScope': store.activeOwnerScope,
    'outbox': store.activeOwnerScope == null ? [] : await store.outbox(),
    'flags': store.activeOwnerScope == null ? [] : await store.flagOutbox(),
    'queue': [for (final card in controller.state.queue) card.toJson()],
    'loading': controller.state.loading,
    'error': controller.state.error,
    'foregroundPasses': foregroundPasses,
    'trace': List<Map<String, dynamic>>.of(trace),
    'operation_witnesses': List<Map<String, dynamic>>.of(operationWitnesses),
  };

  Future<Object?> execute(Map<String, dynamic> command) async {
    final op = command['op'];
    if (op == 'open') {
      if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceSha)) {
        throw StateError('Build requires exact SYNC_LAB_SOURCE_SHA');
      }
      if (deviceId != null) throw StateError('Browser device already opened');
      deviceId = command['deviceId'] as String;
      await switchAccount(command['userId'] as String?);
      foreground.start();
      return status();
    }
    if (deviceId == null) throw StateError('Open browser device first');
    final entry = Map<String, dynamic>.from(command['entry'] as Map? ?? {});
    switch (op) {
      case 'enqueue':
        return {'pending': await store.enqueueReview(entry)};
      case 'enqueueFlag':
        return {'pendingFlags': await store.enqueueFlag(entry)};
      case 'flush':
        await controller.syncPending();
        return status();
      case 'wake':
        await foreground.sync();
        return status();
      case 'switchAccount':
        await switchAccount(command['userId'] as String?);
        return status();
      case 'undo':
        final removed = await store.removeEntry(command['eventId'] as Object);
        return {'removed': removed.removed, 'remaining': removed.remaining};
      case 'controllerUndo':
        await controller.undo();
        return status();
      case 'refresh':
        await controller.refresh();
        return status();
      case 'fetchQueue':
        return {
          'cards': [for (final card in await api.fetchQueue()) card.toJson()],
        };
      case 'readCardSnapshot':
        final ids = (command['cardIds'] as List)
            .map((id) => (id as num).toInt())
            .toList();
        if (ids.isEmpty) {
          throw const FormatException('Explicit cardIds required');
        }
        final cards = await client
            .from('cards')
            .select('id,stability,difficulty,due,state,reps,lapses,last_review')
            .inFilter('id', ids)
            .order('id');
        return {'cards': cards, 'surface': 'FlutterWeb.SupabaseClient.select'};
      case 'status':
        return status();
      case 'dispose':
        foreground.dispose();
        controller.dispose();
        await client.dispose();
        return {'disposed': true};
      default:
        throw ArgumentError.value(op, 'op', 'Unknown browser operation');
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final driver = _BrowserDriver();
  _command = ((JSString raw) => (() async {
    try {
      final command = jsonDecode(raw.toDart) as Map<String, dynamic>;
      final firstRequest = driver.requestSequence + 1;
      final result = await runZoned(
        () => driver.execute(command),
        zoneValues: {#syncLabCommandId: command['commandId']},
      );
      driver.operationWitnesses.add({
        'commandId': command['commandId'],
        'op': command['op'],
        'surface': 'FlutterWeb.ReviewController',
        'sourceSha': _BrowserDriver.sourceSha,
        'firstRequestId': firstRequest,
        'lastRequestId': driver.requestSequence,
        'completed': true,
      });
      return jsonEncode({'ok': true, 'result': result}).toJS;
    } catch (error) {
      return jsonEncode({'ok': false, 'error': error.toString()}).toJS;
    }
  })().toJS).toJS;
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('Synthetic Recall sync lab'),
    ),
  );
}

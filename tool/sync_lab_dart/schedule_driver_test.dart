// Owned synthetic lab adapter. Run only under an admitted resource budget.
// This bridge never opens an Internet connection; actual RecallApi requests
// are serialized to the controlling scratch-SQL runner over a Unix socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/data/review_replay.dart';
import 'file_preferences.dart';

class _Device {
  LocalReviewStore store;
  final SupabaseClient client;
  String? userId;
  _Device(this.store, this.client, this.userId);
  RecallApi get api => RecallApi(client);
}

class _Driver {
  final Socket socket;
  final LabFilePreferences preferences;
  final devices = <String, _Device>{};
  final pending = <int, Completer<Map<String, dynamic>>>{};
  final trace = <Map<String, dynamic>>[];
  int sequence = 0;
  _Driver(this.socket, this.preferences);

  void send(Map<String, dynamic> frame) => socket.writeln(jsonEncode(frame));

  Future<http.Response> transport(String deviceId, http.Request request) async {
    final requestId = ++sequence;
    final waiting = Completer<Map<String, dynamic>>();
    pending[requestId] = waiting;
    final frame = <String, dynamic>{
      'kind': 'transport',
      'requestId': requestId,
      'deviceId': deviceId,
      'userId': devices[deviceId]?.userId,
      'method': request.method,
      'path': request.url.path,
      'url': request.url.toString(),
      'query': request.url.queryParametersAll,
      'headers': request.headers,
      'body': request.body,
    };
    trace.add({...frame, 'surface': 'RecallApi.http'});
    send(frame);
    try {
      final response = await waiting.future.timeout(
        const Duration(seconds: 30),
      );
      if (response['ok'] != true) {
        throw http.ClientException(
          response['error']?.toString() ?? 'injected transport failure',
        );
      }
      final status = response['status'];
      final body = response['body'];
      if (status is! int || body is! String) {
        throw const FormatException(
          'Transport requires status integer and body JSON string',
        );
      }
      trace.add({
        'surface': 'RecallApi.http.response',
        'requestId': requestId,
        'status': status,
      });
      return http.Response(
        body,
        status,
        headers: {
          'content-type': 'application/json',
          ...Map<String, String>.from(response['headers'] as Map? ?? {}),
        },
        request: request,
      );
    } finally {
      pending.remove(requestId);
    }
  }

  Future<Object?> execute(Map<String, dynamic> command) async {
    final op = command['op'] as String;
    final deviceId = command['deviceId'] as String;
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(deviceId)) {
      throw const FormatException('Unsafe deviceId');
    }
    preferences.deviceId = deviceId;
    if (op == 'open') {
      if (devices.containsKey(deviceId)) {
        throw StateError('Device already open');
      }
      // This Flutter test bridge lives under tool/, outside analyzer test discovery.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.resetStatic();
      final store = LocalReviewStore();
      // Force this instance to obtain its device's preferences before another
      // instance resets the SharedPreferences singleton.
      await store.installId();
      final userId = command['userId'] as String?;
      if (userId != null) await store.activateOwner(userId);
      final client = SupabaseClient(
        'https://recall-sync-lab.invalid',
        'synthetic-not-a-credential',
        httpClient: MockClient((request) => transport(deviceId, request)),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      devices[deviceId] = _Device(store, client, userId);
      return {'opened': true, 'storage': 'synthetic-file-platform-adapter'};
    }
    final device = devices[deviceId];
    if (device == null) throw StateError('Device must be opened first');
    final store = device.store;
    final entry = Map<String, dynamic>.from(command['entry'] as Map? ?? {});
    switch (op) {
      case 'enqueue':
        return {'pending': await store.enqueueReview(entry)};
      case 'enqueueFlag':
        return {'pendingFlags': await store.enqueueFlag(entry)};
      case 'undoFlag':
        return {
          'removed': await store.removeFlagEntry(command['eventId'] as Object),
        };
      case 'undo':
        final result = await store.removeEntry(command['eventId'] as Object);
        return {'removed': result.removed, 'remaining': result.remaining};
      case 'markAttempted':
        return {
          'marked': await store.markReviewAttempted(
            command['eventId'] as Object,
          ),
        };
      case 'remoteUndo':
        // Production fail-closed method must throw before any HTTP call.
        await device.api.undoReview(entry);
        return {'unexpectedSuccess': true};
      case 'status':
        return {
          'outbox': await store.outbox(),
          'flags': await store.flagOutbox(),
          'ownerScope': store.activeOwnerScope,
          'userId': device.userId,
          'installId': await store.installId(),
        };
      case 'switchAccount':
        final userId = command['userId'] as String?;
        if (userId == null) {
          await store.releaseOwner();
        } else {
          await store.activateOwner(userId);
        }
        device.userId = userId;
        return {'userId': userId, 'ownerScope': store.activeOwnerScope};
      case 'reopen':
        // This Flutter test bridge lives under tool/, outside analyzer test discovery.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.resetStatic();
        final fresh = LocalReviewStore();
        await fresh.installId();
        if (device.userId != null) await fresh.activateOwner(device.userId!);
        if (device.userId == null && store.ownerAware) {
          await fresh.releaseOwner();
        }
        device.store = fresh;
        return {'reopened': true, 'ownerScope': fresh.activeOwnerScope};
      case 'failNextWrite':
        preferences.failNextWrite = true;
        return {'armed': true};
      case 'flush':
        final ownerScope = store.activeOwnerScope;
        final ownerId = device.userId;
        if (ownerId == null || !store.isActiveOwner(ownerId)) {
          throw StateError('Flush requires an active synthetic owner');
        }
        var delivered = 0;
        for (final queued in await store.outbox(ownerScope: ownerScope)) {
          if (!await store.markReviewAttempted(
            queued['client_id'] as Object,
            ownerScope: ownerScope,
          )) {
            continue;
          }
          final logId = await device.api.applyReview(queued);
          trace.add({
            'surface': 'RecallApi.applyReview',
            'eventId': queued['client_id'],
            'logId': logId,
          });
          if (command['failAckWrite'] == true && delivered == 0) {
            preferences.failNextWrite = true;
          }
          await store.removeFirst(1, ownerScope: ownerScope);
          delivered++;
        }
        return {
          'delivered': delivered,
          'pending': (await store.outbox(ownerScope: ownerScope)).length,
        };
      case 'applyReview':
        return {'logId': await device.api.applyReview(entry)};
      case 'flushFlags':
        final ownerScope = store.activeOwnerScope;
        final ownerId = device.userId;
        if (ownerId == null || !store.isActiveOwner(ownerId)) {
          throw StateError('Flag flush requires an active synthetic owner');
        }
        var delivered = 0;
        for (final queued in await store.flagOutbox(ownerScope: ownerScope)) {
          // This adapter exercises the real API and durable store. It does
          // not claim to exercise the controller's session-race guards.
          if (queued['op'] == 'dismiss') {
            await device.api.dismissFlag(
              cardId: (queued['card_id'] as num).toInt(),
              clientEventId: queued['client_id'].toString(),
            );
          } else {
            await device.api.applyFlag(queued);
          }
          trace.add({
            'surface': queued['op'] == 'dismiss'
                ? 'RecallApi.dismissFlag'
                : 'RecallApi.applyFlag',
            'eventId': queued['client_id'],
          });
          if (command['failAckWrite'] == true && delivered == 0) {
            preferences.failNextWrite = true;
          }
          await store.removeFirstFlag(1, ownerScope: ownerScope);
          delivered++;
        }
        return {
          'delivered': delivered,
          'pending': (await store.flagOutbox(ownerScope: ownerScope)).length,
          'surface': 'RecallApi+LocalReviewStore.adapter',
        };
      case 'fetchHiddenCardIds':
        final ids = (await device.api.fetchHiddenCardIds()).toList()..sort();
        return {'cardIds': ids, 'surface': 'RecallApi.fetchHiddenCardIds'};
      case 'fetchQueue':
        final included = command['includedDeckIds'] as List?;
        final excluded = command['excludeCardIds'] as List? ?? const [];
        final cards = await device.api.fetchQueue(
          deckId: (command['deckId'] as num?)?.toInt(),
          includedDeckIds: included?.map((id) => (id as num).toInt()).toSet(),
          newLimit: (command['newLimit'] as num?)?.toInt() ?? 20,
          excludeCardIds: excluded.map((id) => (id as num).toInt()).toSet(),
        );
        trace.add({
          'surface': 'RecallApi.fetchQueue',
          'count': cards.length,
          'cardIds': [for (final card in cards) card.id],
        });
        return {
          'cards': [for (final card in cards) card.toJson()],
          'cardIds': [for (final card in cards) card.id],
          'count': cards.length,
          'surface': 'RecallApi.fetchQueue',
        };
      case 'readCardStates':
        final cards = <Map<String, dynamic>>[];
        for (final id in command['cardIds'] as List) {
          final cardId = (id as num).toInt();
          final state = await device.api.readCardState(cardId);
          cards.add({
            'id': cardId,
            'exists': state != null,
            if (state != null) ...{
              'reps': state.reps,
              'lapses': state.lapses,
              'last_review': state.lastReview?.toUtc().toIso8601String(),
              'last_review_unreadable': state.lastReviewUnreadable,
            },
          });
        }
        trace.add({
          'surface': 'RecallApi.readCardState',
          'cardIds': command['cardIds'],
        });
        return {'cards': cards, 'surface': 'RecallApi.readCardState'};
      case 'readCardSnapshot':
        final ids = (command['cardIds'] as List)
            .map((id) => (id as num).toInt())
            .toList();
        if (ids.isEmpty) {
          throw const FormatException('Snapshot requires explicit cardIds');
        }
        // Unlike fetchQueue this also sees future-due cards. Values come from
        // the real SDK SELECT response, never the generator or a local model.
        final cards = await device.client
            .from('cards')
            .select('id,stability,difficulty,due,state,reps,lapses,last_review')
            .inFilter('id', ids)
            .order('id');
        trace.add({
          'surface': 'SupabaseClient.cards.select',
          'cardIds': ids,
          'count': cards.length,
        });
        return {'cards': cards, 'surface': 'SupabaseClient.cards.select'};
      case 'legacyMerge':
        return {
          'values': mergeReviewIntoCard(
            server: CardSyncState.fromRow(
              Map<String, dynamic>.from(command['server'] as Map),
            ),
            entry: entry,
          ),
          'surface': 'legacy-helper-only',
          'countsAsSchedule': false,
        };
      case 'parallel':
        final commands = (command['commands'] as List).cast<Map>();
        // SharedPreferences is a process singleton: only one device may race
        // within a command. Cross-device transport scheduling lives outside.
        const allowed = {
          'enqueue',
          'undo',
          'markAttempted',
          'enqueueFlag',
          'undoFlag',
        };
        return Future.wait([
          for (final child in commands)
            if (allowed.contains(child['op']))
              execute({
                ...Map<String, dynamic>.from(child),
                'deviceId': deviceId,
              })
            else
              Future<Object?>.error(
                ArgumentError('Unsupported parallel operation'),
              ),
        ]);
      default:
        throw ArgumentError.value(op, 'op');
    }
  }

  Future<void> close() async {
    for (final device in devices.values) {
      await device.client.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('synthetic real-client schedule bridge', () async {
    final socketPath = Platform.environment['SYNC_LAB_SOCKET'];
    final prefsPath = Platform.environment['SYNC_LAB_PREFS_DIR'];
    if (socketPath == null || prefsPath == null) {
      throw StateError(
        'Explicit owned SYNC_LAB_SOCKET and SYNC_LAB_PREFS_DIR required',
      );
    }
    final directory = Directory(prefsPath);
    if (File('${directory.path}/.sync-lab-owned').readAsStringSync() !=
        'recall-sync-lab-synthetic-v1\n') {
      throw StateError('Missing scratch ownership marker');
    }
    if ((directory.statSync().mode & 0x3f) != 0) {
      throw StateError('Preferences directory must be private 0700');
    }
    final preferences = LabFilePreferences(directory);
    SharedPreferencesStorePlatform.instance = preferences;
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final driver = _Driver(socket, preferences);
    final finished = Completer<void>();
    Future<void> tail = Future.value();
    final subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final frame = jsonDecode(line) as Map<String, dynamic>;
            if (frame['kind'] == 'transport_result') {
              final pending = driver.pending[frame['requestId']];
              if (pending == null || pending.isCompleted) {
                driver.send({
                  'kind': 'protocol_error',
                  'error': 'Unknown transport reply',
                  'requestId': frame['requestId'],
                });
              } else {
                pending.complete(frame);
              }
              return;
            }
            tail = tail.then((_) async {
              if (frame['op'] == 'shutdown') {
                driver.send({
                  'kind': 'result',
                  'id': frame['id'],
                  'ok': true,
                  'result': {'shutdown': true},
                });
                if (!finished.isCompleted) finished.complete();
                return;
              }
              driver.trace.clear();
              preferences.trace.clear();
              try {
                final result = await driver.execute(frame);
                driver.send({
                  'kind': 'result',
                  'id': frame['id'],
                  'deviceId': frame['deviceId'],
                  'ok': true,
                  'result': result,
                  'trace': [...driver.trace, ...preferences.trace],
                });
              } catch (error, stack) {
                driver.send({
                  'kind': 'result',
                  'id': frame['id'],
                  'deviceId': frame['deviceId'],
                  'ok': false,
                  'errorType': '${error.runtimeType}',
                  'error': '$error',
                  'trace': [...driver.trace, ...preferences.trace],
                  'stack': '$stack',
                });
              }
            });
          },
          onError: (Object error, StackTrace stack) {
            if (!finished.isCompleted) finished.completeError(error, stack);
          },
          onDone: () {
            if (!finished.isCompleted) {
              finished.completeError(
                StateError('Runner disconnected without shutdown'),
              );
            }
          },
        );
    driver.send({
      'kind': 'ready',
      'protocol': 'recall-sync-lab-dart-v1',
      'countsAsSchedule': false,
      'sourceHashes': {
        for (final path in [
          'lib/features/review/data/review_replay.dart',
          'lib/features/review/data/recall_api.dart',
          'lib/features/review/data/local_review_store.dart',
          'lib/features/review/application/review_controller.dart',
          'tool/sync_lab_dart/schedule_driver_test.dart',
          'tool/sync_lab_dart/file_preferences.dart',
          'tool/sync_lab_dart/replay_driver.dart',
        ])
          path: sha256.convert(File(path).readAsBytesSync()).toString(),
      },
    });
    try {
      await finished.future;
      await tail;
    } finally {
      await subscription.cancel();
      await driver.close();
      await socket.close();
    }
  }, timeout: const Timeout(Duration(minutes: 25)));
}

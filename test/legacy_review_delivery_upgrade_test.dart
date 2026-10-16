// Baseline-compatible upgrade coverage using only existing public APIs.
// All persisted rows, API responses and owner ids are invented fixtures.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

const _legacy = <String, dynamic>{
  'card_id': 42,
  'guid': 'invented-upgrade-guid',
  'stability': 2.5,
  'difficulty': 4.0,
  'due': '2026-07-14T12:00:00.000Z',
  'state': 2,
  'reps': 3,
  'lapses': 0,
  'last_review': '2026-07-13T12:34:56.789Z',
  'rating': 3,
  'device': 'invented-old-android',
};

Map<String, dynamic> _newer() => {
  ..._legacy,
  'card_id': 43,
  'client_id': 'invented-newer-event',
  'delivery_attempted': false,
};

class _QuietAuthApi extends RecallApi {
  _QuietAuthApi(super.client, {this.user});

  final User? user;

  @override
  User? get currentUser => user;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream<AuthState>.empty();
}

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> hold() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

InMemorySharedPreferencesStore _install(
  List<Map<String, dynamic>> rows, {
  List<Map<String, dynamic>> flags = const [],
}) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = InMemorySharedPreferencesStore.withData({
    'flutter.recall_outbox_v1': jsonEncode(rows),
    'flutter.flag_outbox_v1': jsonEncode(flags),
  });
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Future<List<dynamic>> _persisted(
  InMemorySharedPreferencesStore native, {
  String? owner,
  bool flag = false,
}) async {
  final values = await native.getAll();
  final base = flag ? 'flag_outbox_v1' : 'recall_outbox_v1';
  final key = 'flutter.$base${owner == null ? '' : ':owner:$owner'}';
  return jsonDecode(values[key] as String? ?? '[]') as List;
}

http.Response _json(http.Request request, String body, {int status = 200}) =>
    http.Response(
      body,
      status,
      request: request,
      headers: {'content-type': 'application/json'},
    );

void _expectLegacyLookup(http.Request request) {
  expect(request.method, 'GET');
  expect(request.url.path, endsWith('/review_log'));
  expect(request.url.queryParameters['card_id'], 'eq.42');
  expect(
    request.url.queryParameters['rating_at'],
    'eq.${_legacy['last_review']}',
  );
  expect(request.url.queryParameters['device'], 'eq.${_legacy['device']}');
  expect(request.url.queryParameters.containsKey('client_event_id'), isFalse);
}

({ReviewController controller, LocalReviewStore store, _QuietAuthApi api}) _tab(
  Future<http.Response> Function(http.Request) handler, {
  LocalReviewStore? store,
  User? user,
}) {
  final client = SupabaseClient(
    'https://recall-fixture.invalid',
    'invented-public-key',
    httpClient: MockClient(handler),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final api = _QuietAuthApi(client, user: user);
  final local = store ?? LocalReviewStore();
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: local,
    haptics: const ReviewHaptics(),
  );
  addTearDown(() async {
    controller.dispose();
    await client.dispose();
  });
  return (controller: controller, store: local, api: api);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pre-client-id review and newer-id suffix synchronize', () async {
    final native = _install([_legacy, _newer()]);
    final requests = <http.Request>[];
    final tab = _tab((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/rpc/apply_review')) {
        expect(
          jsonDecode(request.body)['p_client_event_id'],
          'invented-newer-event',
        );
        return _json(request, '78');
      }
      if (request.method == 'GET' && request.url.path.endsWith('/review_log')) {
        _expectLegacyLookup(request);
        return _json(request, '[]');
      }
      if (request.method == 'GET' && request.url.path.endsWith('/cards')) {
        return _json(request, '{"reps":2,"lapses":0,"last_review":null}');
      }
      if (request.method == 'PATCH' && request.url.path.endsWith('/cards')) {
        return _json(request, '[{"id":42}]');
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/review_log')) {
        final payload = jsonDecode(request.body) as Map;
        expect(payload.containsKey('client_event_id'), isFalse);
        expect(payload['rating_at'], _legacy['last_review']);
        expect(payload['device'], _legacy['device']);
        return _json(request, '{"id":77}', status: 201);
      }
      throw StateError('Unexpected invented upgrade request');
    });

    await tab.controller.syncPending();

    expect(
      await _persisted(native),
      isEmpty,
      reason: 'LEGACY_UPGRADE_DRAINS_WITHOUT_NEW_EVENT_ID',
    );
    expect(requests.map((request) => request.method), [
      'GET',
      'GET',
      'PATCH',
      'POST',
      'POST',
    ]);
    expect(
      requests.where(
        (request) => request.url.path.endsWith('/rpc/apply_review'),
      ),
      hasLength(1),
    );
    expect(tab.controller.state.pendingSync, 0);
  });

  test('explicit null client id retains the original legacy lookup', () async {
    final native = _install([
      {..._legacy, 'client_id': null},
    ]);
    final requests = <http.Request>[];
    final tab = _tab((request) async {
      requests.add(request);
      _expectLegacyLookup(request);
      return _json(request, '[{"id":77}]');
    });
    await tab.controller.syncPending();
    expect(await _persisted(native), isEmpty);
    expect(requests, hasLength(1));
  });

  test(
    'lost legacy insert ACK retries the original tuple without applying twice',
    () async {
      final native = _install([_legacy]);
      final requests = <http.Request>[];
      var logged = false;
      final tab = _tab((request) async {
        requests.add(request);
        if (request.method == 'GET' &&
            request.url.path.endsWith('/review_log')) {
          _expectLegacyLookup(request);
          return _json(request, logged ? '[{"id":77}]' : '[]');
        }
        if (request.method == 'GET' && request.url.path.endsWith('/cards')) {
          return _json(request, '{"reps":2,"lapses":0,"last_review":null}');
        }
        if (request.method == 'PATCH' && request.url.path.endsWith('/cards')) {
          return _json(request, '[{"id":42}]');
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/review_log')) {
          expect(logged, isFalse);
          final payload = jsonDecode(request.body) as Map;
          expect(payload.containsKey('client_event_id'), isFalse);
          expect(payload['rating_at'], _legacy['last_review']);
          expect(payload['device'], _legacy['device']);
          logged = true;
          throw http.ClientException('Invented lost insert acknowledgement');
        }
        throw StateError('Unexpected invented lost-ACK request');
      });
      await tab.controller.syncPending();
      expect(await _persisted(native), [_legacy]);
      await tab.controller.syncPending();
      expect(await _persisted(native), isEmpty);
      expect(requests.map((request) => request.method), [
        'GET',
        'GET',
        'PATCH',
        'POST',
        'GET',
      ]);
      expect(
        requests.any(
          (request) => request.url.path.endsWith('/rpc/apply_review'),
        ),
        isFalse,
      );
    },
  );

  test(
    'duplicate legacy server ACK preserves another unacknowledged legacy review',
    () async {
      final b = {..._legacy, 'card_id': 43};
      final native = _install([_legacy, b]);
      final firstGate = _Gate();
      final secondGate = _Gate();
      addTearDown(firstGate.open);
      addTearDown(secondGate.open);
      var bAttempts = 0;
      Future<http.Response> handler(http.Request request, _Gate gate) async {
        expect(request.url.path, endsWith('/review_log'));
        if (request.url.queryParameters['card_id'] == 'eq.42') {
          _expectLegacyLookup(request);
          await gate.hold();
          return _json(request, '[{"id":77}]');
        }
        expect(request.url.queryParameters['card_id'], 'eq.43');
        bAttempts++;
        // A 400 response is one deterministic refused lookup. A transport
        // exception would exercise the SDK's independent GET retry policy.
        return _json(
          request,
          '{"code":"INVENTED_REFUSAL","message":"Synthetic B not acknowledged"}',
          status: 400,
        );
      }

      final first = _tab((request) => handler(request, firstGate));
      final second = _tab((request) => handler(request, secondGate));
      final firstSync = first.controller.syncPending();
      await firstGate.entered.future.timeout(const Duration(seconds: 5));
      final secondSync = second.controller.syncPending();
      await secondGate.entered.future.timeout(const Duration(seconds: 5));
      firstGate.open();
      await firstSync;
      expect(await _persisted(native), [b]);
      secondGate.open();
      await secondSync;
      expect(await _persisted(native), [b]);
      expect(bAttempts, 2);
    },
  );

  for (final badId in ['null', '1.5']) {
    test(
      'legacy malformed server ACK $badId keeps the original review',
      () async {
        final native = _install([_legacy]);
        var reads = 0;
        final tab = _tab((request) async {
          _expectLegacyLookup(request);
          reads++;
          return _json(request, '[{"id":$badId}]');
        });
        await tab.controller.syncPending();
        await tab.controller.syncPending();
        expect(reads, 2);
        expect(await _persisted(native), [_legacy]);
      },
    );
  }

  test(
    'legacy ACK uses captured owner and preserves a fresh payload conflict',
    () async {
      final native = _install([_legacy]);
      final store = LocalReviewStore();
      await store.activateOwner('invented-owner-a');
      final ownerA = store.activeOwnerScope!;
      final gate = _Gate();
      addTearDown(gate.open);
      final tab = _tab(
        (request) async {
          _expectLegacyLookup(request);
          await gate.hold();
          return _json(request, '[{"id":77}]');
        },
        store: store,
        user: User(
          id: 'invented-owner-a',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
      final sync = tab.controller.syncPending();
      await gate.entered.future.timeout(const Duration(seconds: 5));
      final changed = {..._legacy, 'rating': 1};
      await native.setValue(
        'String',
        'flutter.recall_outbox_v1:owner:$ownerA',
        jsonEncode([changed]),
      );
      await store.activateOwner('invented-owner-b');
      final ownerB = store.activeOwnerScope!;
      final otherOwner = {..._legacy, 'card_id': 44};
      await native.setValue(
        'String',
        'flutter.recall_outbox_v1:owner:$ownerB',
        jsonEncode([otherOwner]),
      );
      gate.open();
      await sync;
      expect(await _persisted(native, owner: ownerA), [changed]);
      expect(await _persisted(native, owner: ownerB), [otherOwner]);
    },
  );

  test(
    'malformed legacy identity stops transport without inventing a client id',
    () async {
      final invalid = <Map<String, dynamic>>[
        {..._legacy}..remove('last_review'),
        {..._legacy, 'last_review': '2026-07-13'},
        {..._legacy, 'last_review': '2026-02-30T12:34:56.789Z'},
        {..._legacy, 'device': '  '},
        {..._legacy, 'card_id': 0},
        {..._legacy, 'card_id': '42'},
        {..._legacy, 'client_id': ''},
        {..._legacy, 'client_id': <String>[]},
      ];
      for (final malformed in invalid) {
        final native = _install([malformed, _newer()]);
        var sent = 0;
        final tab = _tab((request) async {
          sent++;
          return _json(request, '77');
        });
        await tab.controller.syncPending();
        await tab.controller.syncPending();
        expect(
          sent,
          0,
          reason: 'Malformed original must stay visible for recovery',
        );
        expect(await _persisted(native), [malformed, _newer()]);
      }
    },
  );

  test(
    'ambiguous equivalent legacy tuples are retained without transport',
    () async {
      final duplicate = {
        ..._legacy,
        'last_review': '2026-07-13T12:34:56.789000Z',
        'rating': 1,
      };
      final native = _install([_legacy, duplicate]);
      var sent = 0;
      final tab = _tab((request) async {
        sent++;
        return _json(request, '[{"id":77}]');
      });
      await tab.controller.syncPending();
      await tab.controller.syncPending();
      expect(sent, 0);
      expect(await _persisted(native), [_legacy, duplicate]);
    },
  );

  test(
    'integer and string wire client-id collisions remain undelivered',
    () async {
      final rows = [
        {..._legacy, 'client_id': 11},
        {..._legacy, 'client_id': '11'},
      ];
      final native = _install(rows);
      var sent = 0;
      final tab = _tab((request) async {
        sent++;
        return _json(request, '77');
      });
      await tab.controller.syncPending();
      expect(sent, 0);
      expect(await _persisted(native), rows);
    },
  );

  test(
    'typed legacy tuple cannot collide with a transport client-id string',
    () async {
      final typedTupleText = (
        legacyReviewCardId: 42,
        ratingAt: DateTime.parse(_legacy['last_review'] as String),
        device: _legacy['device'] as String,
      ).toString();
      final native = _install([
        _legacy,
        {..._newer(), 'client_id': typedTupleText},
      ]);
      var legacyReads = 0;
      var rpcCalls = 0;
      final tab = _tab((request) async {
        if (request.url.path.endsWith('/rpc/apply_review')) {
          expect(jsonDecode(request.body)['p_client_event_id'], typedTupleText);
          rpcCalls++;
          return _json(request, '78');
        }
        _expectLegacyLookup(request);
        legacyReads++;
        return _json(request, '[{"id":77}]');
      });
      await tab.controller.syncPending();
      expect(await _persisted(native), isEmpty);
      expect(legacyReads, 1);
      expect(rpcCalls, 1);
    },
  );

  test(
    'identical stable-id copies synchronize and unblock a valid suffix',
    () async {
      final duplicate = {..._legacy, 'client_id': 'invented-duplicate-event'};
      final native = _install([
        duplicate,
        {...duplicate, 'delivery_attempted': true},
        _newer(),
      ]);
      final serverEvents = <String>{};
      final calls = <String>[];
      final tab = _tab((request) async {
        expect(request.url.path, endsWith('/rpc/apply_review'));
        final eventId = jsonDecode(request.body)['p_client_event_id'] as String;
        calls.add(eventId);
        serverEvents.add(eventId); // Models server deduplication by event id.
        return _json(
          request,
          eventId == 'invented-duplicate-event' ? '77' : '78',
        );
      });
      await tab.controller.syncPending();
      expect(await _persisted(native), isEmpty);
      expect(calls, [
        'invented-duplicate-event',
        'invented-duplicate-event',
        'invented-newer-event',
      ]);
      expect(serverEvents, {
        'invented-duplicate-event',
        'invented-newer-event',
      });
    },
  );

  test(
    'identical legacy copies deduplicate and unblock a valid suffix',
    () async {
      final native = _install([
        _legacy,
        {..._legacy, 'delivery_attempted': true},
        _newer(),
      ]);
      var legacyReads = 0;
      var suffixCalls = 0;
      final tab = _tab((request) async {
        if (request.url.path.endsWith('/rpc/apply_review')) {
          expect(
            jsonDecode(request.body)['p_client_event_id'],
            'invented-newer-event',
          );
          suffixCalls++;
          return _json(request, '78');
        }
        _expectLegacyLookup(request);
        legacyReads++;
        return _json(request, '[{"id":77}]');
      });
      await tab.controller.syncPending();
      expect(await _persisted(native), isEmpty);
      expect(legacyReads, 2);
      expect(suffixCalls, 1);
    },
  );

  test('legacy review tuple does not admit an unidentified flag', () async {
    final flag = {..._legacy, 'reason': 'wrong'};
    final native = _install([], flags: [flag]);
    var sent = 0;
    final tab = _tab((request) async {
      sent++;
      return _json(request, '77');
    });
    await tab.controller.syncPending();
    await tab.controller.syncPending();
    expect(sent, 0);
    expect(await _persisted(native, flag: true), [flag]);
  });
}

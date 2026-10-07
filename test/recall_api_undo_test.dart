import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

const _ownerId = '00000000-0000-0000-0000-000000000001';
const _eventId = 'a79af113-8e38-4ffd-9e2b-871c88ca725c';
const _restore = <String, dynamic>{
  'card_id': 42,
  'guid': 'g42',
  'review_log_id': 77,
  'client_id': _eventId,
  'expected_last_review': '2026-10-07T12:00:00.000Z',
  'expected_reps': 4,
  'expected_lapses': 1,
  'stability': 10.0,
  'difficulty': 5.0,
  'due': '2026-10-06T12:00:00.000Z',
  'state': 2,
  'reps': 3,
  'lapses': 1,
  'last_review': '2026-09-25T12:00:00.000Z',
  'cloud_seen': true,
};

class _Transport {
  final requests = <http.Request>[];
  Map<String, dynamic> card = {
    'id': 42,
    'guid': 'g42',
    'user_id': _ownerId,
    'stability': 12.0,
    'difficulty': 4.0,
    'state': 2,
    'cloud_seen': true,
    'reps': 4,
    'lapses': 1,
    'last_review': _restore['expected_last_review'],
    'due': '2026-10-20T12:00:00.000Z',
  };
  Map<String, dynamic>? log = {
    'id': 77,
    'card_id': 42,
    'guid': 'g42',
    'user_id': _ownerId,
    'client_event_id': _eventId,
  };
  void Function()? beforePatch;
  bool failPatch = false;
  String? deleteFailure;
  bool failReadback = false;
  void Function()? afterDelete;
  Future<void> Function()? beforeLogRead;
  bool patched = false;

  http.Response json(http.Request request, Object? body, {int status = 200}) =>
      http.Response(
        jsonEncode(body),
        status,
        request: request,
        headers: {'content-type': 'application/json'},
      );

  Future<http.Response> send(http.Request request) async {
    if (request.url.path.endsWith('/token')) {
      return json(request, {
        'access_token': 'invented-access',
        'token_type': 'bearer',
        'expires_in': 3600,
        'refresh_token': 'invented-refresh',
        'user': {
          'id': _ownerId,
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': 'invented@example.invalid',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'created_at': '2026-10-01T00:00:00Z',
        },
      });
    }
    if (request.url.path.endsWith('/logout')) {
      return http.Response('', 204, request: request);
    }
    requests.add(request);
    if (request.method == 'GET') {
      if (patched && failReadback) {
        return json(request, {
          'code': '08006',
          'message': 'invented readback outage',
        }, status: 503);
      }
      if (request.url.path.endsWith('/review_log')) {
        await beforeLogRead?.call();
        return json(request, log == null ? [] : [log]);
      }
      return json(request, [card]);
    }
    if (request.method == 'PATCH') {
      beforePatch?.call();
      if (failPatch) {
        return json(request, {
          'code': '08006',
          'message': 'invented outage',
        }, status: 503);
      }
      final query = request.url.queryParameters;
      final matches = [
        'id',
        'guid',
        'user_id',
        'last_review',
        'reps',
        'lapses',
      ].every((key) => query[key] == 'eq.${card[key]}');
      if (!matches) return json(request, []);
      card.addAll(jsonDecode(request.body) as Map<String, dynamic>);
      patched = true;
      return json(request, [
        {'id': 42},
      ]);
    }
    if (request.method == 'DELETE') {
      if (deleteFailure == 'before') {
        throw http.ClientException(
          'Invented delete response failed before commit',
        );
      }
      final query = request.url.queryParameters;
      if (log != null &&
          [
            'id',
            'card_id',
            'guid',
            'user_id',
            'client_event_id',
          ].every((key) => query[key] == 'eq.${log![key]}')) {
        log = null;
      }
      afterDelete?.call();
      if (deleteFailure == 'after') {
        throw http.ClientException(
          'Invented response lost after delete commit',
        );
      }
      return http.Response('', 204, request: request);
    }
    throw StateError('Unexpected invented request');
  }

  Future<RecallApi> api() async {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient(send),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final api = RecallApi(client);
    await api.signIn(
      email: 'invented@example.invalid',
      password: 'invented-password',
    );
    return api;
  }
}

void main() {
  test(
    'own latest review restores by CAS then deletes only its exact log',
    () async {
      final transport = _Transport();
      await (await transport.api()).undoReview(_restore);
      expect(transport.requests.map((r) => r.method), [
        'GET',
        'PATCH',
        'DELETE',
        'GET',
        'GET',
      ]);
      for (final request in [transport.requests.first, transport.requests[2]]) {
        expect(request.url.queryParameters['id'], 'eq.77');
        expect(request.url.queryParameters['card_id'], 'eq.42');
        expect(request.url.queryParameters['guid'], 'eq.g42');
        expect(request.url.queryParameters['user_id'], 'eq.$_ownerId');
        expect(request.url.queryParameters['client_event_id'], 'eq.$_eventId');
      }
      final patch = transport.requests[1];
      expect(
        patch.url.queryParameters['last_review'],
        'eq.${_restore['expected_last_review']}',
      );
      expect(patch.url.queryParameters['reps'], 'eq.4');
      expect(patch.url.queryParameters['lapses'], 'eq.1');
      expect(patch.url.queryParameters['select'], 'id');
      expect(transport.card['reps'], 3);
      expect(transport.card['last_review'], _restore['last_review']);
      expect(transport.log, isNull);
    },
  );

  for (final newer in [
    {'last_review': '2026-10-07T13:00:00.000Z', 'reps': 5, 'lapses': 2},
    {'last_review': _restore['expected_last_review'], 'reps': 5, 'lapses': 1},
    {'last_review': _restore['expected_last_review'], 'reps': 4, 'lapses': 2},
  ]) {
    test('newer or tied-time counters refuse stale undo: $newer', () async {
      final transport = _Transport();
      transport.card.addAll(newer);
      final before = Map<String, dynamic>.from(transport.card);
      await expectLater(
        (await transport.api()).undoReview(_restore),
        throwsA(isA<UndoConflictException>()),
      );
      expect(transport.card, before);
      expect(transport.log, isNotNull);
      expect(transport.requests.where((r) => r.method == 'DELETE'), isEmpty);
    });
  }

  test('a review landing after the log probe wins the CAS race', () async {
    final transport = _Transport();
    transport.beforePatch = () => transport.card.addAll({
      'reps': 5,
      'last_review': '2026-10-07T13:00:00.000Z',
      'due': '2026-11-10T12:00:00.000Z',
    });
    await expectLater(
      (await transport.api()).undoReview(_restore),
      throwsA(isA<UndoConflictException>()),
    );
    expect(transport.card['reps'], 5);
    expect(transport.card['due'], '2026-11-10T12:00:00.000Z');
    expect(transport.log, isNotNull);
    expect(transport.requests.map((r) => r.method), ['GET', 'PATCH']);
  });

  for (final mismatch in [
    null,
    {
      'id': 78,
      'card_id': 42,
      'guid': 'g42',
      'user_id': _ownerId,
      'client_event_id': _eventId,
    },
    {
      'id': 77,
      'card_id': 99,
      'guid': 'g42',
      'user_id': _ownerId,
      'client_event_id': _eventId,
    },
    {
      'id': 77,
      'card_id': 42,
      'guid': 'g42',
      'user_id': _ownerId,
      'client_event_id': 'another-event',
    },
    {
      'id': 77,
      'card_id': 42,
      'guid': 'another-guid',
      'user_id': _ownerId,
      'client_event_id': _eventId,
    },
    {
      'id': 77,
      'card_id': 42,
      'guid': 'g42',
      'user_id': 'another-owner',
      'client_event_id': _eventId,
    },
  ]) {
    test(
      'a missing or mismatched owned receipt cannot write: $mismatch',
      () async {
        final transport = _Transport()..log = mismatch;
        final before = Map<String, dynamic>.from(transport.card);
        await expectLater(
          (await transport.api()).undoReview(_restore),
          throwsA(isA<UndoConflictException>()),
        );
        expect(transport.card, before);
        expect(transport.requests.map((r) => r.method), ['GET']);
      },
    );
  }

  test('a second undo cannot repeat the restore or delete', () async {
    final transport = _Transport();
    final api = await transport.api();
    await api.undoReview(_restore);
    final before = Map<String, dynamic>.from(transport.card);
    await expectLater(
      api.undoReview(_restore),
      throwsA(isA<UndoConflictException>()),
    );
    expect(transport.card, before);
    expect(transport.requests.map((r) => r.method), [
      'GET',
      'PATCH',
      'DELETE',
      'GET',
      'GET',
      'GET',
    ]);
  });

  test(
    'legacy undo without event or outcome ownership expires before requests',
    () async {
      final transport = _Transport();
      await expectLater(
        (await transport.api()).undoReview({
          'card_id': 42,
          'review_log_id': 77,
        }),
        throwsA(isA<UndoConflictException>()),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'a transport failure stays retryable and cannot delete the log',
    () async {
      final transport = _Transport()..failPatch = true;
      await expectLater(
        (await transport.api()).undoReview(_restore),
        throwsA(isA<PostgrestException>()),
      );
      expect(transport.card['reps'], 4);
      expect(transport.log, isNotNull);
      expect(transport.requests.where((r) => r.method == 'DELETE'), isEmpty);
      transport.failPatch = false;
      await (await transport.api()).undoReview(_restore);
      expect(transport.card['reps'], 3);
      expect(transport.log, isNull);
    },
  );
  test(
    'lost delete response is successful only after exact restored-state readback',
    () async {
      final transport = _Transport()..deleteFailure = 'after';
      await (await transport.api()).undoReview(_restore);
      expect(transport.card['reps'], 3);
      expect(transport.log, isNull);
      expect(
        transport.requests.where((r) => r.method == 'PATCH'),
        hasLength(1),
      );
      expect(
        transport.requests.where((r) => r.method == 'DELETE'),
        hasLength(1),
      );
    },
  );

  test(
    'delete failure with surviving log expires without another restore or delete',
    () async {
      final transport = _Transport()..deleteFailure = 'before';
      await expectLater(
        (await transport.api()).undoReview(_restore),
        throwsA(isA<UndoConflictException>()),
      );
      expect(transport.card['reps'], 3);
      expect(transport.log, isNotNull);
      expect(
        transport.requests.where((r) => r.method == 'PATCH'),
        hasLength(1),
      );
      expect(
        transport.requests.where((r) => r.method == 'DELETE'),
        hasLength(1),
      );
    },
  );

  test(
    'newer review after restore and delete expires instead of rewinding the queue',
    () async {
      final transport = _Transport();
      transport.afterDelete = () => transport.card.addAll({
        'reps': 4,
        'last_review': '2026-10-07T13:00:00.000Z',
        'due': '2026-11-01T12:00:00.000Z',
      });
      await expectLater(
        (await transport.api()).undoReview(_restore),
        throwsA(isA<UndoConflictException>()),
      );
      expect(transport.card['due'], '2026-11-01T12:00:00.000Z');
      expect(transport.log, isNull);
      expect(
        transport.requests.where((r) => r.method == 'PATCH'),
        hasLength(1),
      );
    },
  );

  test(
    'unreadable post-write state expires the saved undo instead of retrying writes',
    () async {
      final transport = _Transport()..failReadback = true;
      await expectLater(
        (await transport.api()).undoReview(_restore),
        throwsA(isA<UndoConflictException>()),
      );
      expect(
        transport.requests.where((r) => r.method == 'PATCH'),
        hasLength(1),
      );
      expect(
        transport.requests.where((r) => r.method == 'DELETE'),
        hasLength(1),
      );
    },
  );

  test(
    'account switch after ownership read cannot mutate either account',
    () async {
      final transport = _Transport();
      final api = await transport.api();
      transport.beforeLogRead = api.signOut;
      await expectLater(
        api.undoReview(_restore),
        throwsA(isA<UndoConflictException>()),
      );
      expect(transport.requests.map((r) => r.method), ['GET']);
      expect(transport.card['reps'], 4);
      expect(transport.log, isNotNull);
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/recall_api.dart';

class _BlockingSessionCallbacks {
  final persistEntered = Completer<void>();
  final persistRelease = Completer<void>();
  final removeEntered = Completer<void>();
  final removeRelease = Completer<void>();
  String? value;

  Future<void> persistSession(String persistSessionString) async {
    value = persistSessionString;
    if (!persistEntered.isCompleted) persistEntered.complete();
    await persistRelease.future;
  }

  Future<void> removePersistedSession() async {
    value = null;
    if (!removeEntered.isCompleted) removeEntered.complete();
    await removeRelease.future;
  }
}

void main() {
  test('native sign-in awaits explicit secure session persistence', () async {
    final storage = _BlockingSessionCallbacks();
    final client = _authClient();
    addTearDown(client.dispose);
    final api = RecallApi(
      client,
      persistSession: storage.persistSession,
      removePersistedSession: storage.removePersistedSession,
    );
    var completed = false;

    final signIn = api
        .signIn(email: 'person@example.com', password: 'secret')
        .then((_) => completed = true);
    await storage.persistEntered.future;

    expect(completed, isFalse);
    expect(
      jsonDecode(storage.value!),
      containsPair('refresh_token', 'refresh'),
    );

    storage.persistRelease.complete();
    await signIn;
    expect(completed, isTrue);
  });

  test('native sign-out awaits secure deletion', () async {
    final storage = _BlockingSessionCallbacks()..persistRelease.complete();
    final client = _authClient();
    addTearDown(client.dispose);
    final api = RecallApi(
      client,
      persistSession: storage.persistSession,
      removePersistedSession: storage.removePersistedSession,
    );
    await api.signIn(email: 'person@example.com', password: 'secret');
    var completed = false;

    final signOut = api.signOut().then((_) => completed = true);
    await storage.removeEntered.future;

    expect(completed, isFalse);

    storage.removeRelease.complete();
    await signOut;
    expect(completed, isTrue);
  });

  test('remote failure completes after Supabase clears local auth', () async {
    final client = _authClient(failLogout: true);
    addTearDown(client.dispose);
    var deletionAttempted = false;
    final api = RecallApi(
      client,
      persistSession: (_) async {},
      removePersistedSession: () async {
        deletionAttempted = true;
      },
    );
    await api.signIn(email: 'person@example.com', password: 'secret');

    await expectLater(api.signOut(), completes);

    expect(deletionAttempted, isTrue);
    expect(client.auth.currentSession, isNull);
  });

  test('native sign-in fails closed when secure persistence fails', () async {
    final client = _authClient();
    addTearDown(client.dispose);
    var deletionAttempted = false;
    final api = RecallApi(
      client,
      persistSession: (_) async => throw StateError('Keychain unavailable'),
      removePersistedSession: () async {
        deletionAttempted = true;
      },
    );

    await expectLater(
      api.signIn(email: 'person@example.com', password: 'secret'),
      throwsStateError,
    );

    expect(client.auth.currentSession, isNull);
    expect(deletionAttempted, isTrue);
  });
}

SupabaseClient _authClient({bool failLogout = false}) {
  return SupabaseClient(
    'https://example.supabase.co',
    'anon-key',
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return http.Response(
          jsonEncode({
            'access_token': 'access',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh',
            'user': {
              'id': '00000000-0000-0000-0000-000000000001',
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'person@example.com',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-07-14T10:00:00.000Z',
              'updated_at': '2026-07-14T10:00:00.000Z',
            },
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.endsWith('/logout')) {
        return http.Response(
          failLogout ? 'offline' : '',
          failLogout ? 503 : 204,
          request: request,
        );
      }
      return http.Response('not found', 404, request: request);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

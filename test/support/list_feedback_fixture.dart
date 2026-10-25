import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';

/// Metadata-only transport fixture. The invalid endpoint and empty key are
/// never used by a network client: every request is handled in memory.
class ListFeedbackFixtureApi implements RecallApi {
  ListFeedbackFixtureApi({List<Map<String, dynamic>> initialFlags = const []})
    : flags = [...initialFlags] {
    addTearDown(() async => _client?.dispose());
  }

  List<Map<String, dynamic>> flags;
  int flagReads = 0;
  bool unavailable = false;
  Future<void> Function()? beforeRead;
  SupabaseClient? _client;

  @override
  SupabaseClient get client {
    if (unavailable) throw StateError('Synthetic unavailable transport');
    return _client ??= SupabaseClient(
      'https://synthetic.invalid',
      '',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        // Detached feedback can arrive during a guarded widget pump.
        if (request.method != 'GET' ||
            request.url.path != '/rest/v1/note_flags') {
          throw StateError('Unexpected synthetic metadata request');
        }
        final nextPage = request.url.queryParameters.containsKey('id');
        if (!nextPage) {
          flagReads++;
          await beforeRead?.call();
        }
        return http.Response(
          jsonEncode(
            nextPage
                ? []
                : [
                    for (var i = 0; i < flags.length; i++)
                      {
                        ...flags[i],
                        'id': i + 1,
                        'client_event_id': flags[i]['client_id'],
                      },
                  ],
          ),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected API access');
}

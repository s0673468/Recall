import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/core/diagnostics/operational_diagnostics.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';

class _RecordingDiagnostics implements OperationalEventRecorder {
  final events = <OperationalCauseCode>[];

  @override
  Future<void> record({
    required OperationalLevel level,
    required OperationalComponent component,
    required OperationalOperation operation,
    required OperationalOutcome outcome,
    required OperationalCauseCode causeCode,
    required bool retryable,
    int? exitCode,
    int? durationMs,
  }) async {
    events.add(causeCode);
  }
}

class _AuthErrorApi extends RecallApi {
  final StreamController<AuthState> authStates;

  _AuthErrorApi(super.client, this.authStates);

  @override
  User? get currentUser => null;

  @override
  Stream<AuthState> get onAuthStateChange => authStates.stream;
}

void main() {
  test(
    'auth stream errors are contained and emit a stable cause code',
    () async {
      final authStates = StreamController<AuthState>();
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final diagnostics = _RecordingDiagnostics();
      final controller = ReviewController(
        api: _AuthErrorApi(client, authStates),
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        diagnostics: diagnostics,
      );
      addTearDown(controller.dispose);
      addTearDown(authStates.close);
      addTearDown(client.dispose);

      authStates.addError(
        StateError('private user, deck, and endpoint must not be logged'),
        StackTrace.fromString('private stack'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(diagnostics.events, [OperationalCauseCode.authStreamError]);
      expect(controller.currentUser, isNull);
    },
  );

  test('foreground sync failure is contained and diagnosed once', () async {
    final diagnostics = _RecordingDiagnostics();
    var refreshes = 0;

    await expectLater(
      runRecallForegroundSync(
        diagnostics: diagnostics,
        syncPending: () async => throw StateError(
          'private card, deck, and endpoint must not be logged',
        ),
        refreshIfIdle: () async {
          refreshes++;
        },
      ),
      completes,
    );

    expect(refreshes, 1);
    expect(diagnostics.events, [OperationalCauseCode.foregroundSyncFailed]);
  });
}

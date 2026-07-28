import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/core/diagnostics/operational_diagnostics.dart';
import 'package:health_anki_flutter/core/diagnostics/recall_error_handlers.dart';

class _MemoryStorage implements OperationalEventStorage {
  String? value;
  Object? readError;
  Object? writeError;

  _MemoryStorage([this.value]);

  @override
  Future<String?> read() async {
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(String encoded) async {
    if (writeError case final error?) throw error;
    value = encoded;
  }
}

class _GatedStorage implements OperationalEventStorage {
  String? value;
  int writes = 0;
  final firstWriteStarted = Completer<void>();
  final releaseFirstWrite = Completer<void>();

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String encoded) async {
    writes++;
    if (writes == 1) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    value = encoded;
  }
}

class _RecordingExporter implements OperationalEventExporter {
  final payloads = <String>[];
  Object? error;

  @override
  Future<void> export(String encoded) async {
    if (error case final value?) throw value;
    payloads.add(encoded);
  }
}

List<Map<String, Object?>> _events(_MemoryStorage storage) =>
    (jsonDecode(storage.value!) as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map((event) => event.cast<String, Object?>())
        .toList();

void main() {
  group('OperationalDiagnostics', () {
    test('writes only the fixed operational-event/v2 envelope', () async {
      final storage = _MemoryStorage();
      final console = <String>[];
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-1',
        commitSha: '0123456789abcdef0123456789abcdef01234567',
        console: console.add,
      );

      await diagnostics.record(
        level: OperationalLevel.error,
        component: OperationalComponent.backgroundSync,
        operation: OperationalOperation.syncPending,
        outcome: OperationalOutcome.failed,
        causeCode: OperationalCauseCode.backgroundSyncFailed,
        retryable: true,
        exitCode: 1,
        durationMs: 250,
      );
      await diagnostics.idle;

      expect(_events(storage), [
        {
          'schema': 'operational-event/v2',
          'timestamp': '2026-07-28T15:00:00.000Z',
          'level': 'error',
          'project': 'recall',
          'component': 'background_sync',
          'operation': 'sync_pending',
          'outcome': 'failed',
          'cause_code': 'sync.background_failed',
          'retryable': true,
          'run_id': 'run-1',
          'commit_sha': '0123456789abcdef0123456789abcdef01234567',
          'exit_code': 1,
          'duration_ms': 250,
        },
      ]);
      expect(
        console.single,
        '[recall][operational-event/v2] background_sync.sync_pending '
        'failed sync.background_failed retryable=true',
      );
    });

    test('keeps an event-count-bounded ring', () async {
      final storage = _MemoryStorage();
      var minute = 0;
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15, minute++),
        runId: 'run-count',
        maxEvents: 2,
        maxEncodedBytes: 4096,
        console: (_) {},
      );

      for (var i = 0; i < 3; i++) {
        unawaited(
          diagnostics.record(
            level: OperationalLevel.error,
            component: OperationalComponent.auth,
            operation: OperationalOperation.observeAuthState,
            outcome: OperationalOutcome.failed,
            causeCode: OperationalCauseCode.authStreamError,
            retryable: true,
          ),
        );
      }
      await diagnostics.idle;

      final events = _events(storage);
      expect(events, hasLength(2));
      expect(events.first['timestamp'], '2026-07-28T15:01:00.000Z');
      expect(events.last['timestamp'], '2026-07-28T15:02:00.000Z');
    });

    test('enforces the encoded-size bound by dropping oldest events', () async {
      final storage = _MemoryStorage();
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-size',
        maxEvents: 20,
        maxEncodedBytes: 375,
        console: (_) {},
      );

      for (var i = 0; i < 4; i++) {
        unawaited(
          diagnostics.record(
            level: OperationalLevel.error,
            component: OperationalComponent.framework,
            operation: OperationalOperation.handleFrameworkError,
            outcome: OperationalOutcome.failed,
            causeCode: OperationalCauseCode.flutterFrameworkError,
            retryable: false,
          ),
        );
      }
      await diagnostics.idle;

      expect(utf8.encode(storage.value!).length, lessThanOrEqualTo(375));
      expect(_events(storage), hasLength(1));
    });

    test('recovers from malformed or non-canonical stored data', () async {
      const privateText = 'card back: private-secret';
      final storage = _MemoryStorage(
        jsonEncode([
          {'schema': 'operational-event/v2', 'detail': privateText},
        ]),
      );
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-recovery',
        console: (_) {},
      );

      await diagnostics.record(
        level: OperationalLevel.error,
        component: OperationalComponent.auth,
        operation: OperationalOperation.observeAuthState,
        outcome: OperationalOutcome.failed,
        causeCode: OperationalCauseCode.authStreamError,
        retryable: true,
      );
      await diagnostics.idle;

      expect(_events(storage), hasLength(1));
      expect(storage.value, isNot(contains(privateText)));
      expect(_events(storage).single.keys, isNot(contains('detail')));
    });

    test(
      'retains canonical events across separate recorder instances',
      () async {
        final storage = _MemoryStorage();
        final first = OperationalDiagnostics(
          storage: storage,
          clock: () => DateTime.utc(2026, 7, 28, 15),
          runId: 'run-first',
          console: (_) {},
        );
        await first.record(
          level: OperationalLevel.error,
          component: OperationalComponent.auth,
          operation: OperationalOperation.observeAuthState,
          outcome: OperationalOutcome.failed,
          causeCode: OperationalCauseCode.authStreamError,
          retryable: true,
        );
        await first.idle;

        final second = OperationalDiagnostics(
          storage: storage,
          clock: () => DateTime.utc(2026, 7, 28, 16),
          runId: 'run-second',
          console: (_) {},
        );
        await second.record(
          level: OperationalLevel.error,
          component: OperationalComponent.framework,
          operation: OperationalOperation.handleFrameworkError,
          outcome: OperationalOutcome.failed,
          causeCode: OperationalCauseCode.flutterFrameworkError,
          retryable: false,
        );
        await second.idle;

        expect(_events(storage).map((event) => event['run_id']), [
          'run-first',
          'run-second',
        ]);
      },
    );

    test('storage and console failures never escape record', () async {
      final storage = _MemoryStorage()
        ..readError = StateError('private read error')
        ..writeError = StateError('private write error');
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-failure',
        console: (_) => throw StateError('private console error'),
      );

      expect(
        () => diagnostics.record(
          level: OperationalLevel.error,
          component: OperationalComponent.auth,
          operation: OperationalOperation.observeAuthState,
          outcome: OperationalOutcome.failed,
          causeCode: OperationalCauseCode.authStreamError,
          retryable: true,
        ),
        returnsNormally,
      );
      await expectLater(diagnostics.idle, completes);
    });

    test(
      'mirrors the exact canonical payload only after storage commits',
      () async {
        final storage = _MemoryStorage();
        final exporter = _RecordingExporter();
        final diagnostics = OperationalDiagnostics(
          storage: storage,
          exporter: exporter,
          clock: () => DateTime.utc(2026, 7, 28, 15),
          runId: 'run-export',
          console: (_) {},
        );

        await diagnostics.record(
          level: OperationalLevel.error,
          component: OperationalComponent.auth,
          operation: OperationalOperation.observeAuthState,
          outcome: OperationalOutcome.failed,
          causeCode: OperationalCauseCode.authStreamError,
          retryable: true,
        );
        await diagnostics.idle;

        expect(exporter.payloads, [storage.value]);
        expect(
          isCanonicalOperationalEventPayload(exporter.payloads.single),
          isTrue,
        );
      },
    );

    test('storage failure does not replace the native mirror', () async {
      final storage = _MemoryStorage()
        ..writeError = StateError('preference write failed');
      final exporter = _RecordingExporter();
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        exporter: exporter,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-no-export',
        console: (_) {},
      );

      await diagnostics.record(
        level: OperationalLevel.error,
        component: OperationalComponent.auth,
        operation: OperationalOperation.observeAuthState,
        outcome: OperationalOutcome.failed,
        causeCode: OperationalCauseCode.authStreamError,
        retryable: true,
      );
      await diagnostics.idle;

      expect(exporter.payloads, isEmpty);
    });

    test('native mirror failure never escapes the diagnostic path', () async {
      final storage = _MemoryStorage();
      final exporter = _RecordingExporter()
        ..error = StateError('native mirror failed');
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        exporter: exporter,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-export-failure',
        console: (_) {},
      );

      await diagnostics.record(
        level: OperationalLevel.error,
        component: OperationalComponent.auth,
        operation: OperationalOperation.observeAuthState,
        outcome: OperationalOutcome.failed,
        causeCode: OperationalCauseCode.authStreamError,
        retryable: true,
      );

      await expectLater(diagnostics.idle, completes);
      expect(storage.value, isNotNull);
    });

    test('framework handlers discard exception and stack contents', () async {
      const privateText = 'deck: private-secret';
      final storage = _MemoryStorage();
      final console = <String>[];
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15),
        runId: 'run-handler',
        console: console.add,
      );

      recordFlutterFrameworkError(
        diagnostics,
        StateError(privateText),
        StackTrace.fromString('private stack $privateText'),
      );
      final handled = recordUncaughtPlatformError(
        diagnostics,
        StateError(privateText),
        StackTrace.fromString('private stack $privateText'),
      );
      expect(handled, isFalse);
      expect(
        console.last,
        contains('handle_uncaught_error failed flutter.uncaught_error'),
      );
      await diagnostics.idle;

      expect(storage.value, isNot(contains(privateText)));
      expect(console.join('\n'), isNot(contains(privateText)));
      expect(_events(storage).map((event) => event['cause_code']), [
        'flutter.framework_error',
        'flutter.uncaught_error',
      ]);
    });

    test('uses an isolated preference without touching card data', () async {
      const privateCard = 'private card front and back';
      SharedPreferences.setMockInitialValues({
        'recall_snapshot_v1': privateCard,
      });
      final diagnostics = await OperationalDiagnostics.create(
        clock: () => DateTime.utc(2026, 7, 28, 15),
        console: (_) {},
      );

      await diagnostics.record(
        level: OperationalLevel.error,
        component: OperationalComponent.auth,
        operation: OperationalOperation.observeAuthState,
        outcome: OperationalOutcome.failed,
        causeCode: OperationalCauseCode.authStreamError,
        retryable: true,
      );
      await diagnostics.idle;

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('recall_snapshot_v1'), privateCard);
      final diagnosticValues = preferences
          .getKeys()
          .map(preferences.getString)
          .whereType<String>()
          .where((value) => value.contains('operational-event/v2'));
      expect(diagnosticValues, hasLength(1));
      expect(diagnosticValues.single, isNot(contains(privateCard)));
    });

    test('bounds pending events and coalesces a write storm', () async {
      final storage = _GatedStorage();
      var second = 0;
      final diagnostics = OperationalDiagnostics(
        storage: storage,
        clock: () => DateTime.utc(2026, 7, 28, 15, 0, second++),
        runId: 'run-storm',
        maxEvents: 10,
        maxPendingEvents: 10,
        maxEncodedBytes: 64 * 1024,
        console: (_) {},
      );

      unawaited(
        diagnostics.record(
          level: OperationalLevel.error,
          component: OperationalComponent.framework,
          operation: OperationalOperation.handleFrameworkError,
          outcome: OperationalOutcome.failed,
          causeCode: OperationalCauseCode.flutterFrameworkError,
          retryable: false,
        ),
      );
      await storage.firstWriteStarted.future;

      for (var i = 0; i < 50; i++) {
        unawaited(
          diagnostics.record(
            level: OperationalLevel.error,
            component: OperationalComponent.framework,
            operation: OperationalOperation.handleFrameworkError,
            outcome: OperationalOutcome.failed,
            causeCode: OperationalCauseCode.flutterFrameworkError,
            retryable: false,
          ),
        );
      }
      storage.releaseFirstWrite.complete();
      await diagnostics.idle;

      expect(storage.writes, 2);
      expect(_events(_MemoryStorage(storage.value)), hasLength(10));
    });
  });
}

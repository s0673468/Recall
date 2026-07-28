import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _schema = 'operational-event/v2';
const _project = 'recall';
const _storageKey = 'recall.operational_events.v2';

enum OperationalLevel {
  error('error');

  final String wireValue;
  const OperationalLevel(this.wireValue);
}

enum OperationalComponent {
  framework('framework'),
  backgroundSync('background_sync'),
  foregroundSync('foreground_sync'),
  auth('auth');

  final String wireValue;
  const OperationalComponent(this.wireValue);
}

enum OperationalOperation {
  handleFrameworkError('handle_framework_error'),
  handleUncaughtError('handle_uncaught_error'),
  syncPending('sync_pending'),
  observeAuthState('observe_auth_state');

  final String wireValue;
  const OperationalOperation(this.wireValue);
}

enum OperationalOutcome {
  started('started'),
  succeeded('succeeded'),
  failed('failed'),
  skipped('skipped');

  final String wireValue;
  const OperationalOutcome(this.wireValue);
}

enum OperationalCauseCode {
  none('none'),
  flutterFrameworkError('flutter.framework_error'),
  flutterUncaughtError('flutter.uncaught_error'),
  backgroundSyncFailed('sync.background_failed'),
  foregroundSyncFailed('sync.foreground_failed'),
  authStreamError('auth.stream_error');

  final String wireValue;
  const OperationalCauseCode(this.wireValue);
}

/// The deliberately narrow interface used by error paths.
///
/// Every value is an allowlisted enum or a bounded number. There is no field
/// through which an exception, stack, card, deck, user, device, path, endpoint,
/// or other arbitrary text can enter the operational event stream.
abstract interface class OperationalEventRecorder {
  Future<void> record({
    required OperationalLevel level,
    required OperationalComponent component,
    required OperationalOperation operation,
    required OperationalOutcome outcome,
    required OperationalCauseCode causeCode,
    required bool retryable,
    int? exitCode,
    int? durationMs,
  });
}

abstract interface class OperationalEventStorage {
  Future<String?> read();
  Future<void> write(String encoded);
}

abstract interface class OperationalEventExporter {
  Future<void> export(String encoded);
}

class SharedPreferencesOperationalEventStorage
    implements OperationalEventStorage {
  final SharedPreferences _preferences;

  const SharedPreferencesOperationalEventStorage(this._preferences);

  @override
  Future<String?> read() async => _preferences.getString(_storageKey);

  @override
  Future<void> write(String encoded) async {
    if (!await _preferences.setString(_storageKey, encoded)) {
      throw StateError('operational diagnostics preference write failed');
    }
  }
}

class _DiscardingOperationalEventStorage implements OperationalEventStorage {
  const _DiscardingOperationalEventStorage();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String encoded) async {}
}

class _DiscardingOperationalEventExporter implements OperationalEventExporter {
  const _DiscardingOperationalEventExporter();

  @override
  Future<void> export(String encoded) async {}
}

class OperationalDiagnostics implements OperationalEventRecorder {
  static const defaultMaxEvents = 100;
  static const defaultMaxEncodedBytes = 64 * 1024;
  static const defaultMaxPendingEvents = 100;

  final OperationalEventStorage _storage;
  final OperationalEventExporter _exporter;
  final DateTime Function() _clock;
  final String _runId;
  final String? _commitSha;
  final int maxEvents;
  final int maxEncodedBytes;
  final int maxPendingEvents;
  final void Function(String) _console;
  final List<Map<String, Object?>> _queued = [];
  Future<void>? _drainTask;

  OperationalDiagnostics({
    required OperationalEventStorage storage,
    OperationalEventExporter exporter =
        const _DiscardingOperationalEventExporter(),
    required DateTime Function() clock,
    required String runId,
    String? commitSha,
    this.maxEvents = defaultMaxEvents,
    this.maxEncodedBytes = defaultMaxEncodedBytes,
    this.maxPendingEvents = defaultMaxPendingEvents,
    void Function(String)? console,
  }) : _storage = storage,
       _exporter = exporter,
       _clock = clock,
       _runId = _validatedRunId(runId),
       _commitSha = _validatedCommitSha(commitSha),
       _console = console ?? debugPrint {
    if (maxEvents < 1) {
      throw ArgumentError.value(maxEvents, 'maxEvents', 'must be positive');
    }
    if (maxEncodedBytes < 2) {
      throw ArgumentError.value(
        maxEncodedBytes,
        'maxEncodedBytes',
        'must fit a JSON array',
      );
    }
    if (maxPendingEvents < 1) {
      throw ArgumentError.value(
        maxPendingEvents,
        'maxPendingEvents',
        'must be positive',
      );
    }
  }

  /// Creates the app sink. Preference initialization failure degrades to a
  /// discard-only store so diagnostics can never block app startup.
  static Future<OperationalDiagnostics> create({
    DateTime Function() clock = DateTime.now,
    String? commitSha,
    OperationalEventExporter exporter =
        const _DiscardingOperationalEventExporter(),
    void Function(String)? console,
  }) async {
    OperationalEventStorage storage;
    try {
      storage = SharedPreferencesOperationalEventStorage(
        await SharedPreferences.getInstance(),
      );
    } catch (_) {
      storage = const _DiscardingOperationalEventStorage();
    }
    return OperationalDiagnostics(
      storage: storage,
      exporter: exporter,
      clock: clock,
      runId: _newRunId(clock),
      commitSha: commitSha,
      console: console,
    );
  }

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
  }) {
    try {
      final event = <String, Object?>{
        'schema': _schema,
        'timestamp': _clock().toUtc().toIso8601String(),
        'level': level.wireValue,
        'project': _project,
        'component': component.wireValue,
        'operation': operation.wireValue,
        'outcome': outcome.wireValue,
        'cause_code': causeCode.wireValue,
        'retryable': retryable,
        'run_id': _runId,
        if (_commitSha != null) 'commit_sha': _commitSha,
        'exit_code': ?exitCode,
        if (durationMs != null) 'duration_ms': max(0, durationMs),
      };
      try {
        _console(
          '[$_project][$_schema] ${component.wireValue}.'
          '${operation.wireValue} ${outcome.wireValue} '
          '${causeCode.wireValue} retryable=$retryable',
        );
      } catch (_) {
        // Console diagnostics are best-effort and never affect the caller.
      }
      if (_queued.length >= maxPendingEvents) {
        _queued.removeAt(0);
      }
      _queued.add(event);
      return _drainTask ??= _drain();
    } catch (_) {
      // Even a failing injected clock must not change app control flow.
      return Future.value();
    }
  }

  Future<void> get idle => _drainTask ?? Future.value();

  Future<void> _drain() async {
    try {
      while (_queued.isNotEmpty) {
        final batch = List<Map<String, Object?>>.from(_queued);
        _queued.clear();
        await _persist(batch);
      }
    } catch (_) {
      // Diagnostics are best-effort and never affect app control flow.
    } finally {
      _drainTask = null;
      if (_queued.isNotEmpty) {
        _drainTask = _drain();
      }
    }
  }

  Future<void> _persist(List<Map<String, Object?>> batch) async {
    var events = <Map<String, Object?>>[];
    try {
      final encoded = await _storage.read();
      if (encoded != null) {
        final decoded = jsonDecode(encoded);
        if (decoded is List<Object?>) {
          events = decoded
              .whereType<Map>()
              .map((item) => Map<String, Object?>.from(item))
              .where(_isCanonicalEvent)
              .toList();
        }
      }
    } catch (_) {
      events = [];
    }

    events.addAll(batch);
    if (events.length > maxEvents) {
      events.removeRange(0, events.length - maxEvents);
    }

    var encoded = jsonEncode(events);
    while (events.isNotEmpty && utf8.encode(encoded).length > maxEncodedBytes) {
      events.removeAt(0);
      encoded = jsonEncode(events);
    }
    try {
      await _storage.write(encoded);
      try {
        await _exporter.export(encoded);
      } catch (_) {
        // A failed diagnostic mirror must not change app behavior.
      }
    } catch (_) {
      // Persistence is isolated from app behavior.
    }
  }
}

class RecallDiagnostics {
  RecallDiagnostics._();

  static OperationalEventRecorder _instance =
      const _DiscardingOperationalEventRecorder();

  static OperationalEventRecorder get instance => _instance;

  static void install(OperationalEventRecorder recorder) {
    _instance = recorder;
  }
}

class _DiscardingOperationalEventRecorder implements OperationalEventRecorder {
  const _DiscardingOperationalEventRecorder();

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
  }) async {}
}

String _newRunId(DateTime Function() clock) {
  try {
    return 'run-${clock().toUtc().microsecondsSinceEpoch.toRadixString(36)}';
  } catch (_) {
    return 'run-unknown';
  }
}

String _validatedRunId(String runId) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(runId)) {
    throw ArgumentError.value(runId, 'runId', 'must be an opaque safe token');
  }
  return runId;
}

String? _validatedCommitSha(String? commitSha) {
  if (commitSha == null) return null;
  if (!RegExp(r'^[0-9a-f]{7,64}$').hasMatch(commitSha)) {
    throw ArgumentError.value(commitSha, 'commitSha', 'must be lowercase hex');
  }
  return commitSha;
}

const _requiredKeys = {
  'schema',
  'timestamp',
  'level',
  'project',
  'component',
  'operation',
  'outcome',
  'cause_code',
  'retryable',
  'run_id',
};
const _optionalKeys = {'commit_sha', 'exit_code', 'duration_ms'};

bool _isCanonicalEvent(Map<String, Object?> event) {
  if (!event.keys.toSet().containsAll(_requiredKeys) ||
      event.keys.any(
        (key) => !_requiredKeys.contains(key) && !_optionalKeys.contains(key),
      )) {
    return false;
  }
  if (event['schema'] != _schema ||
      event['project'] != _project ||
      !OperationalLevel.values.any(
        (value) => value.wireValue == event['level'],
      ) ||
      !OperationalComponent.values.any(
        (value) => value.wireValue == event['component'],
      ) ||
      !OperationalOperation.values.any(
        (value) => value.wireValue == event['operation'],
      ) ||
      !OperationalOutcome.values.any(
        (value) => value.wireValue == event['outcome'],
      ) ||
      !OperationalCauseCode.values.any(
        (value) => value.wireValue == event['cause_code'],
      ) ||
      event['retryable'] is! bool) {
    return false;
  }
  final timestamp = event['timestamp'];
  final runId = event['run_id'];
  if (timestamp is! String ||
      DateTime.tryParse(timestamp) == null ||
      runId is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(runId)) {
    return false;
  }
  final commitSha = event['commit_sha'];
  if (commitSha != null &&
      (commitSha is! String ||
          !RegExp(r'^[0-9a-f]{7,64}$').hasMatch(commitSha))) {
    return false;
  }
  return (event['exit_code'] == null || event['exit_code'] is int) &&
      (event['duration_ms'] == null ||
          (event['duration_ms'] is int && (event['duration_ms'] as int) >= 0));
}

bool isCanonicalOperationalEventPayload(
  String encoded, {
  int maxEncodedBytes = OperationalDiagnostics.defaultMaxEncodedBytes,
}) {
  try {
    if (utf8.encode(encoded).length > maxEncodedBytes) return false;
    final decoded = jsonDecode(encoded);
    if (decoded is! List<Object?> ||
        decoded.length > OperationalDiagnostics.defaultMaxEvents) {
      return false;
    }
    return decoded.every(
      (event) =>
          event is Map && _isCanonicalEvent(Map<String, Object?>.from(event)),
    );
  } catch (_) {
    return false;
  }
}
